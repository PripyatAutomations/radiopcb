// Filter type
#include <stdint.h>
#define	FILTER_NONE		0x0000
#define	FILTER_LPF		0x0001
#define	FILTER_BPF		0x0002
#define	FILTER_HPF		0x0004
#define	FILTER_NOTCH		0x0010


struct rf_filter {
    uint32_t	f_type;
};