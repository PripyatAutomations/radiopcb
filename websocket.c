#include "config.h"
#include <stddef.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include "i2c.h"
#include "state.h"
#include "eeprom.h"
#include "logger.h"
#include "cat.h"
#include "posix.h"
#include "websocket.h"

extern bool dying;		// in main.c
extern time_t now;		// in main.c
extern struct GlobalState rig;	// Global state

// Our websocket client list for broadcasting messages & chat
static struct ws_client *client_list = NULL;

bool ws_init(struct mg_mgr *mgr) {
   if (mgr == NULL) {
      Log(LOG_CRIT, "ws", "ws_init called with NULL mgr");
      return true;
   }

   return false;
}

// Broadcast a message to all WebSocket clients (using http_client_list)
void ws_broadcast(struct mg_connection *sender_conn, struct mg_str *msg_data) {
   http_client_t *current = http_client_list;  // Iterate over all clients

   while (current != NULL) {
      // Only send to WebSocket clients
      if (current->is_ws && current->conn != sender_conn) {
         mg_ws_send(current->conn, msg_data->buf, msg_data->len, WEBSOCKET_OP_TEXT);
      }
      current = current->next;
   }
}

void hash_to_hex(char *dest, const uint8_t *hash, size_t len) {
   for (size_t i = 0; i < len; i++) {
      sprintf(dest + (i * 2), "%02x", hash[i]);  // Convert each byte to hex
   }
   dest[len * 2] = '\0'; 			 // Null-terminate the string
}



bool ws_send_userlist(void) {
   char resp_buf[512];
   int len = mg_snprintf(resp_buf, sizeof(resp_buf), "{ \"talk\": { \"cmd\": \"names\", \"users\": [");

   int count = 0;
   for (int i = 0; i < HTTP_MAX_USERS; i++) {
      if (http_users[i].enabled) {
         len += mg_snprintf(resp_buf + len, sizeof(resp_buf) - len, "%s\"%s\"", count++ ? "," : "", http_users[i].user);
         if (len >= sizeof(resp_buf)) break;  // Prevent buffer overflow
      }
   }

   mg_snprintf(resp_buf + len, sizeof(resp_buf) - len, "] } }");

   // Send the response over WebSocket (assuming you have a valid `c` connection)
   // mg_ws_send(c, resp_buf, strlen(resp_buf), WEBSOCKET_OP_TEXT);
   
   return false;
}

void ws_blorp_userlist_cb(void *arg) {
   ws_send_userlist();
   (void)arg;
}

bool ws_kick_client(http_client_t *cptr, const char *reason) {
   char resp_buf[512];
   struct mg_connection *c = cptr->conn;
   
   if (cptr == NULL || cptr->conn == NULL) {
      Log(LOG_DEBUG, "auth.noisy", "ws_kick_client for cptr <%x> has mg_conn <%x> and is invalid", cptr, (cptr != NULL ? cptr->conn : NULL));
      return true;
   }

   memset(resp_buf, 0, sizeof(resp_buf));
   snprintf(resp_buf, sizeof(resp_buf), "{ \"auth\": { \"error\": \"Disconnected: %s.\" } }", reason);
   mg_ws_send(c, resp_buf, strlen(resp_buf), WEBSOCKET_OP_TEXT);
   mg_ws_send(c, "", 0, WEBSOCKET_OP_CLOSE);
   http_remove_client(c);

   return false;
}

bool ws_kick_client_by_c(struct mg_connection *c, const char *reason) {
   char resp_buf[512];

   http_client_t *cptr = http_find_client_by_c(c);
   
   if (cptr == NULL || cptr->conn == NULL) {
      Log(LOG_DEBUG, "auth.noisy", "ws_kick_client_by_c for mg_conn <%x> has cptr <%x> and is invalid", c, (cptr != NULL ? cptr->conn : NULL));
      return true;
   }

   return ws_kick_client(cptr, reason);
}

bool ws_handle(struct mg_ws_message *msg, struct mg_connection *c) {
   struct mg_str msg_data = msg->data;

//     Log(LOG_DEBUG, "http.noisy", "WS msg: %.*s", (int) msg->data.len, msg->data.buf);

   // Handle different message types...
   if (mg_json_get(msg_data, "$.cat", NULL) > 0) {
      // Handle cat-related messages
   } else if (mg_json_get(msg_data, "$.talk", NULL) > 0) {
      Log(LOG_DEBUG, "chat.noisy", "Got message from client: |%.*s|", msg_data.len, msg_data.buf);
      char *cmd = mg_json_get_str(msg_data, "$.talk.cmd");
      char *data = mg_json_get_str(msg_data, "$.talk.data");
      char *token = mg_json_get_str(msg_data, "$.talk.token");

      http_client_t *cptr = http_find_client_by_token(token);

      if (cptr == NULL) {
         Log(LOG_DEBUG, "chat", "talk parse, cptr == NULL, token: |%s|", token);
         return true;
      }

      if (cmd && data) {
         // Handle the 'msg', 'kick', and 'mute' commands
         if (strcmp(cmd, "msg") == 0) {
            char msgbuf[512];
            struct mg_str mp;
            memset(msgbuf, 0, sizeof(msgbuf));
            snprintf(msgbuf, sizeof(msgbuf), "{ \"talk\": { \"from\": \"%s\", \"cmd\": \"msg\", \"data\": \"%s\" } }", cptr->user, data);
            Log(LOG_DEBUG, "chat.noisy", "sending |%s| (%lu of %lu max bytes) to all clients", msgbuf, strlen(msgbuf), sizeof(msgbuf));
            mp = mg_str(msgbuf);
            ws_broadcast(c, &mp);
         } else if (strcmp(cmd, "kick") == 0) {
            Log(LOG_INFO, "chat", "Kick command received, processing...");
         } else if (strcmp(cmd, "mute") == 0) {
            Log(LOG_INFO, "chat", "Mute command received, processing...");
         } else {
            Log(LOG_WARN, "chat", "Unknown talk command: %s", cmd);
         }

         // Free the allocated memory after use
         free(cmd);
         free(data);
      }
   } else if (mg_json_get(msg_data, "$.auth", NULL) > 0) {
      char *cmd = mg_json_get_str(msg_data, "$.auth.cmd");
      char *user = mg_json_get_str(msg_data, "$.auth.user");

      if (strcmp(cmd, "login") == 0) {
         // Construct the response
         char resp_buf[512];
         srand((unsigned int)time(NULL));
         memset(resp_buf, 0, sizeof(resp_buf));
         Log(LOG_DEBUG, "auth.noisy", "Login request from user %s", user);

         http_client_t *cptr = http_add_client(c, true);
         if (cptr == NULL) {
            return true;
         }
         memset(cptr->user, 0, sizeof(cptr->user));
         memcpy(cptr->user, user, sizeof(cptr->user));

         snprintf(resp_buf, sizeof(resp_buf), 
                  "{ \"auth\": { \"cmd\": \"challenge\", \"nonce\": \"%s\", \"user\": \"%s\", \"token\": \"%s\" } }", 
                  cptr->nonce, user, cptr->token);
         mg_ws_send(c, resp_buf, strlen(resp_buf), WEBSOCKET_OP_TEXT);
         Log(LOG_DEBUG, "auth.noisy", "Sending login challenge |%s| to user", resp_buf);
      } else if (strcmp(cmd, "logout") == 0) {
         char *token = mg_json_get_str(msg_data, "$.auth.token");
         Log(LOG_DEBUG, "auth.noisy", "Logout request from session token |%s|", (token != NULL ? token : "NONE"));
         ws_kick_client_by_c(c, "Logged out");
      } else if (strcmp(cmd, "pass") == 0) {
         char *pass = mg_json_get_str(msg_data, "$.auth.pass");
         char *req_token = mg_json_get_str(msg_data, "$.auth.token");
         char *token = mg_json_get_str(msg_data, "$.auth.token");

         if (pass == NULL) {
            ws_kick_client_by_c(c, "auth/pass ws msg without password");
         }

         http_client_t *cptr = http_find_client_by_token(token);
         int login_uid = cptr->uid;
         Log(LOG_DEBUG, "auth.noisy", "PASS: cptr <%x>", cptr);

         if (cptr == NULL) {
            Log(LOG_DEBUG, "auth", "Unable to find client in PASS parsing");
            http_dump_clients();
         } else {
            Log(LOG_DEBUG, "auth.noisy", "PASS from cptr <%x> with token |%s|", cptr, token);
         }

         if (login_uid < 0 || login_uid > HTTP_MAX_USERS) {
            Log(LOG_DEBUG, "auth.noisy", "Couldn't find uid for username %s", cptr->user);
            ws_kick_client(cptr, "Invalid login");
            return true;
         }

         // Address the user database entry
         http_user_t *up = &http_users[login_uid];
         if (up == NULL) {
            Log(LOG_DEBUG, "auth.noisy", "Uid %d returned NULL http_user_t", login_uid);
            return true;
         }

         if (strcmp(up->pass, pass) == 0) {
            cptr->authenticated = true;
            char resp_buf[512];
            memset(resp_buf, 0, sizeof(resp_buf));
            snprintf(resp_buf, sizeof(resp_buf), 
                     "{ \"auth\": { \"cmd\": \"authorized\", \"user\": \"%s\", \"token\": \"%s\" } }", 
                     user, token);
            mg_ws_send(c, resp_buf, strlen(resp_buf), WEBSOCKET_OP_TEXT);
            Log(LOG_DEBUG, "auth.noisy", "Sending |%s| to user", resp_buf);
         } else {
            ws_kick_client(cptr, "Invalid login");
         }
      }
   }

   return false;
}
