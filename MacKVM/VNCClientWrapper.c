/*
 * VNCClientWrapper.c
 * Minimal RFB 3.8 client implementation using BSD sockets.
 * Supports VNC Authentication (type 2) with DES challenge-response.
 * Pixel format: requests 32bpp BGRA for direct use as CGImage data.
 */

#include "VNCClientWrapper.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <CommonCrypto/CommonCrypto.h>

// ---------------------------------------------------------------------------
// VNC DES auth using Apple CommonCrypto.
// VNC auth spec: encrypt 16-byte server challenge with 8-byte password key
// using DES-ECB. Key bytes have their bits reversed before use.
// ---------------------------------------------------------------------------

static void vnc_des_encrypt(const uint8_t password[8],
                             const uint8_t challenge[16],
                             uint8_t response[16]) {
    // Reverse bits in each byte of the password to form the DES key
    uint8_t key[8];
    for (int i = 0; i < 8; i++) {
        uint8_t b = password[i];
        b = ((b & 0xF0) >> 4) | ((b & 0x0F) << 4);
        b = ((b & 0xCC) >> 2) | ((b & 0x33) << 2);
        b = ((b & 0xAA) >> 1) | ((b & 0x55) << 1);
        key[i] = b;
    }
    size_t bytesOut = 0;
    CCCrypt(kCCEncrypt, kCCAlgorithmDES, kCCOptionECBMode,
            key, kCCKeySizeDES,
            NULL,
            challenge, 16,
            response, 16,
            &bytesOut);
}

// ---------------------------------------------------------------------------
// RFB message type constants
// ---------------------------------------------------------------------------

#define RFB_SET_PIXEL_FORMAT     0
#define RFB_SET_ENCODINGS        2
#define RFB_FRAMEBUFFER_UPDATE_REQ 3
#define RFB_KEY_EVENT            4
#define RFB_POINTER_EVENT        5

#define RFB_FRAMEBUFFER_UPDATE   0
#define RFB_BELL                 2
#define RFB_SERVER_CUT_TEXT      3

#define RFB_ENCODING_RAW         0
#define RFB_ENCODING_COPYRECT    1
#define RFB_ENCODING_ZRLE        16
#define RFB_ENCODING_CURSOR      0xFFFFFF11
#define RFB_ENCODING_DESKTOPSIZE 0xFFFFFF21

// ---------------------------------------------------------------------------
// Client handle
// ---------------------------------------------------------------------------

struct VNCClientHandle {
    int sock;
    char password[256];
    char last_error[512];

    int fb_width;
    int fb_height;
    unsigned char *framebuffer; // BGRA

    VNCFramebufferCallback fb_callback;
    void *fb_userdata;

    VNCErrorCallback err_callback;
    void *err_userdata;

    volatile int running;
    pthread_t recv_thread;
};

// ---------------------------------------------------------------------------
// I/O helpers
// ---------------------------------------------------------------------------

static int read_exact(int sock, void *buf, size_t len) {
    size_t total = 0;
    while (total < len) {
        ssize_t n = recv(sock, (char *)buf + total, len - total, 0);
        if (n <= 0) return -1;
        total += (size_t)n;
    }
    return 0;
}

static int write_exact(int sock, const void *buf, size_t len) {
    size_t total = 0;
    while (total < len) {
        ssize_t n = send(sock, (const char *)buf + total, len - total, 0);
        if (n <= 0) return -1;
        total += (size_t)n;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

VNCClientHandle *vncclient_create(void) {
    VNCClientHandle *c = (VNCClientHandle *)calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->sock = -1;
    return c;
}

void vncclient_set_password(VNCClientHandle *client, const char *password) {
    if (!client || !password) return;
    strncpy(client->password, password, sizeof(client->password) - 1);
}

void vncclient_set_framebuffer_callback(VNCClientHandle *client,
                                        VNCFramebufferCallback callback,
                                        void *userdata) {
    if (!client) return;
    client->fb_callback = callback;
    client->fb_userdata = userdata;
}

void vncclient_set_error_callback(VNCClientHandle *client,
                                  VNCErrorCallback callback,
                                  void *userdata) {
    if (!client) return;
    client->err_callback = callback;
    client->err_userdata = userdata;
}

const char *vncclient_last_error(VNCClientHandle *client) {
    if (!client) return "null client";
    return client->last_error;
}

int vncclient_framebuffer_width(VNCClientHandle *client) {
    return client ? client->fb_width : 0;
}

int vncclient_framebuffer_height(VNCClientHandle *client) {
    return client ? client->fb_height : 0;
}

// ---------------------------------------------------------------------------
// Send helpers
// ---------------------------------------------------------------------------

static int send_set_pixel_format(int sock) {
    // 32bpp BGRA: bits-per-pixel=32, depth=24, big-endian=0, true-colour=1
    // r/g/b max=255, r-shift=16, g-shift=8, b-shift=0  (BGRX layout)
    uint8_t msg[20] = {0};
    msg[0] = RFB_SET_PIXEL_FORMAT;
    // 3 bytes padding
    // PixelFormat (16 bytes starting at offset 4)
    msg[4]  = 32;  // bits-per-pixel
    msg[5]  = 24;  // depth
    msg[6]  = 0;   // big-endian
    msg[7]  = 1;   // true-colour
    // r-max
    msg[8]  = 0; msg[9]  = 255;
    // g-max
    msg[10] = 0; msg[11] = 255;
    // b-max
    msg[12] = 0; msg[13] = 255;
    // r-shift=16, g-shift=8, b-shift=0
    msg[14] = 16;
    msg[15] = 8;
    msg[16] = 0;
    // 3 bytes padding
    return write_exact(sock, msg, sizeof(msg));
}

static int send_set_encodings(int sock) {
    uint8_t msg[8];
    msg[0] = RFB_SET_ENCODINGS;
    msg[1] = 0; // padding
    msg[2] = 0; msg[3] = 1; // number-of-encodings = 1
    // Raw encoding = 0
    int32_t enc = htonl(RFB_ENCODING_RAW);
    memcpy(msg + 4, &enc, 4);
    return write_exact(sock, msg, sizeof(msg));
}

static int send_framebuffer_update_request(int sock, int incremental,
                                           int x, int y, int w, int h) {
    uint8_t msg[10];
    msg[0] = RFB_FRAMEBUFFER_UPDATE_REQ;
    msg[1] = (uint8_t)incremental;
    uint16_t nx = htons((uint16_t)x);
    uint16_t ny = htons((uint16_t)y);
    uint16_t nw = htons((uint16_t)w);
    uint16_t nh = htons((uint16_t)h);
    memcpy(msg + 2, &nx, 2);
    memcpy(msg + 4, &ny, 2);
    memcpy(msg + 6, &nw, 2);
    memcpy(msg + 8, &nh, 2);
    return write_exact(sock, msg, sizeof(msg));
}

// ---------------------------------------------------------------------------
// Receive loop (runs on background thread)
// ---------------------------------------------------------------------------

static void report_error(VNCClientHandle *c, const char *msg) {
    strncpy(c->last_error, msg, sizeof(c->last_error) - 1);
    fprintf(stderr, "[VNC] Error: %s\n", msg);
    if (c->err_callback)
        c->err_callback(msg, c->err_userdata);
}

static void *recv_loop(void *arg) {
    VNCClientHandle *c = (VNCClientHandle *)arg;

    while (c->running) {
        uint8_t msg_type;
        if (read_exact(c->sock, &msg_type, 1) < 0) {
            if (c->running)
                report_error(c, "Connection lost");
            break;
        }

        if (msg_type == RFB_FRAMEBUFFER_UPDATE) {
            uint8_t padding;
            read_exact(c->sock, &padding, 1);
            uint16_t nrects_n;
            read_exact(c->sock, &nrects_n, 2);
            int nrects = ntohs(nrects_n);

            for (int r = 0; r < nrects; r++) {
                uint16_t rx_n, ry_n, rw_n, rh_n;
                int32_t enc_n;
                read_exact(c->sock, &rx_n, 2);
                read_exact(c->sock, &ry_n, 2);
                read_exact(c->sock, &rw_n, 2);
                read_exact(c->sock, &rh_n, 2);
                read_exact(c->sock, &enc_n, 4);

                int rx = ntohs(rx_n);
                int ry = ntohs(ry_n);
                int rw = ntohs(rw_n);
                int rh = ntohs(rh_n);
                int32_t enc = ntohl(enc_n);

                if (enc == RFB_ENCODING_RAW) {
                    int bytes = rw * rh * 4; // 32bpp
                    // Allocate or grow framebuffer if needed
                    int fbsize = c->fb_width * c->fb_height * 4;
                    if (!c->framebuffer && fbsize > 0) {
                        c->framebuffer = (unsigned char *)calloc(1, (size_t)fbsize);
                    }
                    if (c->framebuffer && bytes > 0) {
                        // Read row by row into correct position
                        uint8_t *rowbuf = (uint8_t *)malloc((size_t)(rw * 4));
                        if (rowbuf) {
                            for (int row = 0; row < rh; row++) {
                                read_exact(c->sock, rowbuf, (size_t)(rw * 4));
                                int dst_y = ry + row;
                                if (dst_y < c->fb_height) {
                                    int copy_cols = (rx + rw <= c->fb_width) ? rw : c->fb_width - rx;
                                    if (copy_cols > 0) {
                                        memcpy(c->framebuffer + (dst_y * c->fb_width + rx) * 4,
                                               rowbuf, (size_t)(copy_cols * 4));
                                    }
                                }
                            }
                            free(rowbuf);
                        } else {
                            // skip
                            uint8_t *skip = (uint8_t *)malloc((size_t)bytes);
                            if (skip) { read_exact(c->sock, skip, (size_t)bytes); free(skip); }
                        }
                    } else if (bytes > 0) {
                        // skip unreadable
                        uint8_t *skip = (uint8_t *)malloc((size_t)bytes);
                        if (skip) { read_exact(c->sock, skip, (size_t)bytes); free(skip); }
                    }

                    // Fire callback
                    if (c->fb_callback && c->framebuffer) {
                        c->fb_callback(c->framebuffer, c->fb_width, c->fb_height, c->fb_userdata);
                    }
                } else {
                    // Unsupported encoding — skip (we can't know size, so we give up)
                    char errmsg[128];
                    snprintf(errmsg, sizeof(errmsg), "Unsupported encoding: %d", enc);
                    report_error(c, errmsg);
                    c->running = 0;
                    break;
                }
            }

            // Request next incremental update
            if (c->running) {
                send_framebuffer_update_request(c->sock, 1,
                                                0, 0, c->fb_width, c->fb_height);
            }
        } else if (msg_type == RFB_BELL) {
            // nothing to do
        } else if (msg_type == RFB_SERVER_CUT_TEXT) {
            uint8_t pad[3];
            read_exact(c->sock, pad, 3);
            uint32_t len_n;
            read_exact(c->sock, &len_n, 4);
            uint32_t len = ntohl(len_n);
            if (len > 0 && len < 65536) {
                char *text = (char *)malloc(len);
                if (text) { read_exact(c->sock, text, len); free(text); }
            }
        } else {
            // Unknown message — can't recover
            char errmsg[128];
            snprintf(errmsg, sizeof(errmsg), "Unknown server message type: %d", msg_type);
            report_error(c, errmsg);
            c->running = 0;
        }
    }

    return NULL;
}

// ---------------------------------------------------------------------------
// Connect and handshake
// ---------------------------------------------------------------------------

int vncclient_connect(VNCClientHandle *client, const char *host, int port) {
    if (!client || !host) return -1;

    // Resolve host
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo *res = NULL;
    int rc = getaddrinfo(host, portstr, &hints, &res);
    if (rc != 0 || !res) {
        snprintf(client->last_error, sizeof(client->last_error),
                 "DNS lookup failed: %s", gai_strerror(rc));
        return -1;
    }

    int sock = -1;
    for (struct addrinfo *p = res; p; p = p->ai_next) {
        sock = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (sock < 0) continue;
        if (connect(sock, p->ai_addr, p->ai_addrlen) == 0) break;
        close(sock);
        sock = -1;
    }
    freeaddrinfo(res);

    if (sock < 0) {
        snprintf(client->last_error, sizeof(client->last_error),
                 "TCP connect failed: %s", strerror(errno));
        return -1;
    }

    client->sock = sock;

    // --- RFB version handshake ---
    char ver[13] = {0};
    if (read_exact(sock, ver, 12) < 0) {
        snprintf(client->last_error, sizeof(client->last_error),
                 "Failed to read server version");
        close(sock); client->sock = -1; return -1;
    }
    ver[12] = '\0';
    fprintf(stderr, "[VNC] Server version: %.12s\n", ver);

    // We negotiate RFB 003.008
    const char *client_ver = "RFB 003.008\n";
    write_exact(sock, client_ver, 12);

    // --- Security handshake ---
    uint8_t nsec;
    if (read_exact(sock, &nsec, 1) < 0 || nsec == 0) {
        // Server sent error
        uint32_t errlen_n;
        char errbuf[256] = {0};
        read_exact(sock, &errlen_n, 4);
        uint32_t errlen = ntohl(errlen_n);
        if (errlen > 0 && errlen < sizeof(errbuf))
            read_exact(sock, errbuf, errlen);
        snprintf(client->last_error, sizeof(client->last_error),
                 "Server refused connection: %s", errbuf);
        close(sock); client->sock = -1; return -1;
    }

    uint8_t sec_types[256];
    if (read_exact(sock, sec_types, nsec) < 0) {
        snprintf(client->last_error, sizeof(client->last_error),
                 "Failed to read security types");
        close(sock); client->sock = -1; return -1;
    }

    // Prefer VNC Authentication (type 2), fall back to None (type 1)
    uint8_t chosen = 0;
    for (int i = 0; i < nsec; i++) {
        if (sec_types[i] == 2) { chosen = 2; break; }
        if (sec_types[i] == 1) chosen = 1;
    }
    if (chosen == 0) {
        snprintf(client->last_error, sizeof(client->last_error),
                 "No supported security type offered by server");
        close(sock); client->sock = -1; return -1;
    }

    write_exact(sock, &chosen, 1);

    if (chosen == 2) {
        // VNC Authentication: server sends 16-byte challenge
        uint8_t challenge[16];
        if (read_exact(sock, challenge, 16) < 0) {
            snprintf(client->last_error, sizeof(client->last_error),
                     "Failed to read VNC auth challenge");
            close(sock); client->sock = -1; return -1;
        }

        uint8_t pw[8] = {0};
        size_t pwlen = strlen(client->password);
        if (pwlen > 8) pwlen = 8;
        memcpy(pw, client->password, pwlen);

        uint8_t response[16];
        vnc_des_encrypt(pw, challenge, response);
        write_exact(sock, response, 16);
    }

    // Security result (not sent for None in 3.3, required in 3.8)
    if (chosen != 1) {
        uint32_t result_n;
        if (read_exact(sock, &result_n, 4) < 0) {
            snprintf(client->last_error, sizeof(client->last_error),
                     "Failed to read security result");
            close(sock); client->sock = -1; return -1;
        }
        uint32_t result = ntohl(result_n);
        if (result != 0) {
            uint32_t errlen_n;
            char errbuf[256] = {0};
            if (read_exact(sock, &errlen_n, 4) == 0) {
                uint32_t errlen = ntohl(errlen_n);
                if (errlen > 0 && errlen < sizeof(errbuf))
                    read_exact(sock, errbuf, errlen);
            }
            snprintf(client->last_error, sizeof(client->last_error),
                     "Authentication failed: %s", errbuf[0] ? errbuf : "Wrong password");
            close(sock); client->sock = -1; return -1;
        }
    }

    // --- ClientInit ---
    uint8_t shared = 1; // share desktop
    write_exact(sock, &shared, 1);

    // --- ServerInit ---
    uint16_t w_n, h_n;
    read_exact(sock, &w_n, 2);
    read_exact(sock, &h_n, 2);
    client->fb_width  = ntohs(w_n);
    client->fb_height = ntohs(h_n);

    // PixelFormat (16 bytes) + name length (4 bytes) + name
    uint8_t pf[16];
    read_exact(sock, pf, 16);
    uint32_t namelen_n;
    read_exact(sock, &namelen_n, 4);
    uint32_t namelen = ntohl(namelen_n);
    if (namelen > 0 && namelen < 4096) {
        char *name = (char *)malloc(namelen + 1);
        if (name) {
            read_exact(sock, name, namelen);
            name[namelen] = '\0';
            fprintf(stderr, "[VNC] Desktop name: %s  size: %dx%d\n",
                    name, client->fb_width, client->fb_height);
            free(name);
        }
    }

    // Allocate framebuffer
    int fbsize = client->fb_width * client->fb_height * 4;
    if (fbsize > 0) {
        client->framebuffer = (unsigned char *)calloc(1, (size_t)fbsize);
        if (!client->framebuffer) {
            snprintf(client->last_error, sizeof(client->last_error),
                     "Out of memory for framebuffer (%dx%d)",
                     client->fb_width, client->fb_height);
            close(sock); client->sock = -1; return -1;
        }
    }

    // Send our preferred pixel format and encoding
    send_set_pixel_format(sock);
    send_set_encodings(sock);

    // Request initial full framebuffer
    send_framebuffer_update_request(sock, 0,
                                    0, 0, client->fb_width, client->fb_height);

    // Start receive thread
    client->running = 1;
    pthread_create(&client->recv_thread, NULL, recv_loop, client);

    fprintf(stderr, "[VNC] Connected to %s:%d (%dx%d)\n",
            host, port, client->fb_width, client->fb_height);
    return 0;
}

void vncclient_send_key_event(VNCClientHandle *client,
                               uint32_t keysym, int down) {
    if (!client || client->sock < 0) return;
    uint8_t msg[8] = {0};
    msg[0] = RFB_KEY_EVENT;
    msg[1] = (uint8_t)(down ? 1 : 0);
    // msg[2..3] padding
    uint32_t ks = htonl(keysym);
    memcpy(msg + 4, &ks, 4);
    write_exact(client->sock, msg, 8);
}

void vncclient_send_pointer_event(VNCClientHandle *client,
                                   int x, int y, int button_mask) {
    if (!client || client->sock < 0) return;
    uint8_t msg[6];
    msg[0] = RFB_POINTER_EVENT;
    msg[1] = (uint8_t)(button_mask & 0xFF);
    uint16_t nx = htons((uint16_t)x);
    uint16_t ny = htons((uint16_t)y);
    memcpy(msg + 2, &nx, 2);
    memcpy(msg + 4, &ny, 2);
    write_exact(client->sock, msg, 6);
}

void vncclient_disconnect(VNCClientHandle *client) {
    if (!client) return;
    client->running = 0;
    if (client->sock >= 0) {
        // Shutdown the socket before closing so recv() in the recv_loop
        // unblocks immediately (SHUT_RDWR sends EOF to the peer and wakes
        // any blocking recv on this end).
        shutdown(client->sock, SHUT_RDWR);
        close(client->sock);
        client->sock = -1;
    }
    // Wait for the receive thread to exit before freeing memory.
    if (client->recv_thread) {
        pthread_join(client->recv_thread, NULL);
        client->recv_thread = 0;
    }
    free(client->framebuffer);
    free(client);
}
