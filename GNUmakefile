SHELL = bash
.SHELLFLAGS = -e -c
all: world

PROFILE ?= radio
CF := config/${PROFILE}.config.json
CHANNELS := config/${PROFILE}.channels.json
BUILD_DIR := build/${PROFILE}
OBJ_DIR := ${BUILD_DIR}/obj
bin := ${BUILD_DIR}/firmware.bin

# Throw an error if the .json configuration file doesn't exist...
ifeq (x$(wildcard ${CF}),x)
$(error ***ERROR*** Please create ${CF} first before building -- There is an example at doc/radio.json.example you can use)
endif

CFLAGS := -std=gnu11 -g -O1 -Wall -Wno-unused -pedantic -std=gnu99
LDFLAGS := -lc -lm -g
CFLAGS += -I${BUILD_DIR} $(strip $(shell cat ${CF} | jq -r ".build.cflags"))
CFLAGS += -DLOGFILE="\"$(strip $(shell cat ${CF} | jq -r '.debug.logfile'))\""
LDFLAGS += $(strip $(shell cat ${CF} | jq -r ".build.ldflags"))
TC_PREFIX := $(strip $(shell cat ${CF} | jq -r ".build.toolchain.prefix"))
EEPROM_SIZE := $(strip $(shell cat ${CF} | jq -r ".eeprom.size"))
EEPROM_FILE := ${BUILD_DIR}/eeprom.bin
PLATFORM := $(strip $(shell cat ${CF} | jq -r ".build.platform"))

ifeq (${PLATFORM},posix)
LDFLAGS += -lgpiod
endif

# Are we cross compiling?
ifneq (${TC_PREFIX},"")
CC := ${TC_PREFIX}-gcc
LD := ${TC_PREFIX}-ld
else
CC := gcc
LD := ld
endif

##################
# Source objects #
##################
objs += amp.o			# Amplifier management
objs += atu.o			# Antenna Tuner
objs += audio.o			# Audio channel stuff
objs += audio.pcm5102.o		# pcm5102 DAC support
objs += cat.o			# CAT parsers
objs += cat_kpa500.o		# amplifier control (KPA-500 mode)
objs += cat_yaesu.o		# Yaesu CAT protocol
objs += channels.o		# Channel Memories
objs += console.o		# Console support
objs += crc32.o			# CRC32 calculation for eeprom verification
objs += dds.o			# API for Direct Digital Synthesizers
objs += dds.ad9833.o		# AD9833 DDS
objs += dds.ad9959_stm32.o	# STM32 (AT command) ad9851 DDS
objs += debug.o			# Debug stuff
objs += eeprom.o		# "EEPROM" configuration storage
objs += faults.o		# Fault management/alerting
objs += filters.o		# Control of input/output filters
objs += gpio.o			# GPIO controls
objs += gui.o			# Support for a local user-interface
objs += gui_fb.o		# Generic LCD (framebuffer) interface
objs += gui_nextion.o		# Nextion HMI display interface
objs += help.o			# support for help menus from filesystem, if available
objs += http.o			# HTTP server
objs += i2c.o			# i2c abstraction
objs += i2c.mux.o		# i2c multiplexor support
objs += io.o			# Input/Output abstraction/portability
objs += logger.o		# Logging facilities
objs += main.o			# main loop
objs += network.o		# Network control

ifeq (${PLATFORM}, posix)
#objs += audio.pipewire.o	# Pipwiere on posix hosts
CFLAGS += $(shell pkg-config --cflags libpipewire-0.3)
LDFLAGS += $(shell pkg-config --libs libpipewire-0.3)
objs += posix.o			# support for POSIX hosts (linux or perhaps others)
endif

objs += power.o			# Power monitoring and management
objs += protection.o		# Protection features
objs += ptt.o			# Push To Talk controls (GPIO, CAT, etc)
objs += serial.o		# Serial port stuff
objs += socket.o		# Socket operations
objs += thermal.o		# Thermal management
objs += timer.o			# Timers support
objs += usb.o			# Support for USB control (stm32)
objs += util_vna.o		# Vector Network Analyzer
objs += vfo.o			# VFO control/management
objs += waterfall.o		# Support for rendering waterfalls
objs += websocket.o		# Websocket transport for CAT and audio

# translate unprefixed object file names to source file names
src_files = $(objs:.o=.c)

# prepend objdir path to each object
real_objs := $(foreach x, ${objs}, ${OBJ_DIR}/${x})

################################################################################
###############
# Build Rules #
###############
# Remove log files, etc
extra_clean += firmware.log
# Remove autogenerated headers on clean
extra_clean += $(wildcard ${BUILD_DIR}/*.h)

# Extra things to build/clean: eeprom image
extra_build += ${EEPROM_FILE}
extra_clean += ${EEPROM_FILE}

world: ${extra_build} ${bin}

BUILD_HEADERS=${BUILD_DIR}/build_config.h ${BUILD_DIR}/eeprom_layout.h $(wildcard *.h) $(wildcard ${BUILD_DIR}/*.h)
${OBJ_DIR}/%.o: %.c ${BUILD_HEADERS}
# delete the old object file, so we can't accidentally link against it...
	@${RM} -f $@
	@${CC} ${CFLAGS} ${extra_cflags} -o $@ -c $<
	@echo "[compile] $@ from $<"

# Binary also depends on the .stamp file
${bin}: ${real_objs}
	@${CC} -o $@ ${real_objs} ${LDFLAGS}
	@echo "[Link] $@ from $(words ${real_objs}) object files..."
	@ls -a1ls $@
	@file $@
	@size $@

strip: ${bin}
	@echo "[strip] ${bin}"
	@strip ${bin}
	@ls -a1ls ${bin}

${BUILD_DIR}/build_config.h ${EEPROM_FILE} buildconf: ${CF} ${CHANNELS} $(wildcard res/*.json) buildconf.pl
	@echo "[buildconf]"
	set -e; ./buildconf.pl ${PROFILE}

##################
# Source Cleanup #
##################
clean:
	@echo "[clean]"
	${RM} ${bin} ${real_objs} ${extra_clean}

distclean: clean
	@echo "[distclean]"
	${RM} -r build
	${RM} -f config/archive/*.json *.log

###############
# DFU Install #
###############
install:
	@echo "Automatic DFU installation isn't supported yet... Please see doc/INSTALLING.txt for more info"

###################
# Running on host #
###################
ifeq (${PLATFORM},posix)
# Run debugger
run: ${EEPROM_FILE} ${bin}
	@echo "[run] ${bin}"
	@${bin}

gdb debug: ${bin} ${EEPROM_FILE}
	@echo "[gdb] ${bin}"
	@gdb ${bin} -ex 'run'

test: clean world run
endif

#################
# Configuration #
#################
res/bandplan.json:
	exit 1

res/eeprom_layout.json:
	exit 1

res/eeprom_types.json:
	exit 1

# Display an error message and halt the build, if no configuration file
${CF}:
	@echo "********************************************************"
	@echo "* PLEASE read README.txt and edit ${CF} as needed *"
	@echo "********************************************************"
	exit 1

installdep:
	apt install libjson-perl libterm-readline-perl-perl libhash-merge-perl libjson-xs-perl libjson-perl libstring-crc32-perl libgpiod-dev
	cpan install Mojo::JSON::Pointer
