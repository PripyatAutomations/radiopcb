/*
 * support logging to a a few places
 *	Targets: syslog console flash (file)
 */
#include "config.h"
#include <stddef.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include "logger.h"
#include "state.h"

extern struct GlobalState rig;	// Global state

/* String constants we use more than a few times */
const char *s_prio_crit = "CRIT",
           *s_prio_warn = "WARN",
           *s_prio_info = "INFO",
           *s_prio_debug = "DBUG",
           *s_none = "NONE";

FILE   *logfp = NULL;

const char *log_priority_to_str(logpriority_t priority) {
   switch (priority) {
      case LOG_CRIT:
         return s_prio_crit;
         break;
      case LOG_WARN:
         return s_prio_warn;
         break;
      case LOG_INFO:
         return s_prio_info;
         break;
      case LOG_DEBUG:
         return s_prio_debug;
         break;
      default:
         return s_none;
         break;
   }
   return NULL;
}

void logger_init(void) {
#if	defined(HOST_POSIX)
/* This really should be HAVE_FS or such, rather than HOST_POSIX as we could log to SD, etc... */
   if (logfp == NULL) {
      logfp = fopen(HOST_LOG_FILE, "a+");

      if (logfp == NULL) {
         return;
      }
      // XXX: do final setup
   }
#else
/* Machdep log setup goes here */
#endif
}

void logger_end(void) {
#if	defined(HOST_POSIX)
/* This really should be HAVE_FS or such, rather than HOST_POSIX as we could log to SD, etc... */
   if (logfp != NULL)
      fclose(logfp);
#else
/* Machdep log teardown goes here */
#endif
}

void Log(logpriority_t priority, const char *fmt, ...) {
   char msgbuf[512];
   char tsbuf[64];
   va_list ap;
   time_t t;
   struct tm *tmp;

   /* clear the message buffer */
   memset(msgbuf, 0, sizeof(msgbuf));

   va_start(ap, fmt);

   /* Expand the format string */
   vsnprintf(msgbuf, 511, fmt, ap);

   memset(tsbuf, 0, sizeof(tsbuf));
   t = time(NULL);

   if ((tmp = localtime(&t)) != NULL) {
      /* success, proceed */
      if (strftime(tsbuf, sizeof(tsbuf), "%Y/%m/%d %H:%M:%S", tmp) == 0) {
         /* handle the error */
         memset(tsbuf, 0, sizeof(tsbuf));
         snprintf(tsbuf, sizeof(tsbuf), "<%lu>", time(NULL));
      }
   }

#if	defined(HOST_POSIX) || defined(FEATURE_FILESYSTEM)
   /* Only spew to the serial port if logfile is closed */
   if (logfp == NULL) {
      // XXX: this should support network targets too!!
//      sio_printf("%s %s: %s\n", tsbuf, log_priority_to_str(priority), msgbuf);
      va_end(ap);
      return;
   } else {
      fprintf(logfp, "%s %s: %s\n", tsbuf, log_priority_to_str(priority), msgbuf);
      fflush(logfp);
   }
#endif

#if	defined(HOST_POSIX)
   // Send it to the stdout too on host builds
   fprintf(stdout, "%s %s: %s\n", tsbuf, log_priority_to_str(priority), msgbuf);
#endif

   /* Machdep logging goes here! */

   va_end(ap);
}
