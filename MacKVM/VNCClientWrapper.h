#ifndef VNCClientWrapper_h
#define VNCClientWrapper_h

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

// Opaque VNC client handle implementing RFB 3.8 protocol over TCP.
typedef struct VNCClientHandle VNCClientHandle;

// Called on each framebuffer update rectangle with BGRA pixel data.
// width/height are the full framebuffer dimensions; the pixel buffer
// covers the entire framebuffer (may be partial updates accumulated).
typedef void (*VNCFramebufferCallback)(const unsigned char * _Nullable pixels,
                                       int width, int height,
                                       void * _Nullable userdata);

// Called when the connection is lost or an error occurs.
typedef void (*VNCErrorCallback)(const char * _Nullable message, void * _Nullable userdata);

// Called when the server sends clipboard text (ServerCutText message).
typedef void (*VNCCutTextCallback)(const char * _Nullable text, uint32_t length, void * _Nullable userdata);

// Creates a new VNC client instance. Returns NULL on allocation failure.
VNCClientHandle * _Nullable vncclient_create(void);

// Sets the VNC password used during authentication.
void vncclient_set_password(VNCClientHandle * _Nullable client, const char * _Nullable password);

// Sets the framebuffer update callback.
void vncclient_set_framebuffer_callback(VNCClientHandle * _Nullable client,
                                        VNCFramebufferCallback _Nullable callback,
                                        void * _Nullable userdata);

// Sets the error/disconnect callback.
void vncclient_set_error_callback(VNCClientHandle * _Nullable client,
                                  VNCErrorCallback _Nullable callback,
                                  void * _Nullable userdata);

// Sets the ServerCutText (remote clipboard) callback.
void vncclient_set_cut_text_callback(VNCClientHandle * _Nullable client,
                                     VNCCutTextCallback _Nullable callback,
                                     void * _Nullable userdata);

// Connects to host:port, performs RFB handshake, and starts the receive
// loop on a background thread. Returns 0 on successful handshake,
// nonzero on failure (check vncclient_last_error for details).
int vncclient_connect(VNCClientHandle * _Nullable client, const char * _Nullable host, int port);

// Returns the last error string (valid until next call or disconnect).
const char * _Nonnull vncclient_last_error(VNCClientHandle * _Nullable client);

// Returns the negotiated framebuffer width/height (valid after connect).
int vncclient_framebuffer_width(VNCClientHandle * _Nullable client);
int vncclient_framebuffer_height(VNCClientHandle * _Nullable client);

// Sends a key event to the server. keysym is an X11 keysym value. Safe to call with nil client.
void vncclient_send_key_event(VNCClientHandle * _Nullable client,
                               uint32_t keysym, int down);

// Sends a pointer (mouse) event to the server. Safe to call with nil client.
void vncclient_send_pointer_event(VNCClientHandle * _Nullable client,
                                   int x, int y, int button_mask);

// Stops the receive loop and frees all resources. Safe to call with nil.
void vncclient_disconnect(VNCClientHandle * _Nullable client);

#ifdef __cplusplus
}
#endif

#endif /* VNCClientWrapper_h */
