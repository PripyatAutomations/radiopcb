#if	!defined(__rr_faults_h)
#define	__rr_faults_h
#include "config.h"
#include <stdbool.h>

// XXX: We need set the highest bit to 1 to indicate that fault is fatal and should halt TX
// A higher (numeric) error will replace a lower numbered one in the fault code register...
// XXX: Sort these by order of severity
#define	FAULT_NONE		0x00	// No faults
#define	FAULT_STUCK_RELAY	0x01	// Power On Self Test determined a relay is stuck
#define	FAULT_INLET_THERMAL	0x02	// Inlet air too hot
#define	FAULT_TOO_HOT		0x03	// Enclosure ambient too high
#define FAULT_HIGH_SWR		0x04	// VSWR is above threshold
#define	FAULT_FINAL_THERMAL	0x05	// Final is too hot
#define	FAULT_FINAL_LOW_CURRENT	0x06	// Final supply current much below expected
#define	FAULT_FINAL_HIGH_CURRENT 0x07	// Final supply current too high
#define	FAULT_FINAL_LOW_VOLT	0x08	// Final supply voltage too low
#define	FAULT_FINAL_HIGH_VOLT	0x09	// Final supply voltage too high
#define	FAULT_TOT_TIMEOUT	0x0a	// TOT Expired

// Last fault needs to be 99 (0x64)
#define	FAULT_UNKNOWN		0x64

struct fault_table {
   uint32_t 	code;			// error code
   bool		fatal;			// Is this a fatal error?
   char		msg[16];		// message string
};

extern struct fault_table fault_table[];

extern uint32_t set_fault(uint32_t code);
extern bool check_faults(void);
extern int fault_priority(uint32_t code);
extern const char *fault_get_type_str(uint32_t code);
extern bool fault_is_fatal(uint32_t code);
extern uint32_t set_fault(uint32_t fault);
extern bool check_faults(void);

#endif	// !defined(__rr_faults_h)
