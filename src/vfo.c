/*
 * Deal with things related to the VFO, such as reconfiguring DDS(es)
 */
#include "config.h"
#include <stddef.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <string.h>
#include "logger.h"
#include "state.h"
#include "vfo.h"
extern struct GlobalState rig;	// Global state