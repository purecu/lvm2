#!/bin/bash
# LVM recovery for disks moved between systems
# Written by Christopher "Sean" Briggs <csbriggs at gmail.com>
# Date: Sept 8, 2024
# Updated: Sept 9, 2024  Corrected LV_NAME question.  Thanks to William Arnold for the feedback.

# MIT License
#
# Copyright (c) 2024 Christopher Sean Briggs <csbriggs at gmail.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Provided as is.  Use at your own risk.

# This version currently assumes LUKS or LVM2 is applied directly on the block device
# the user specifies.  It currenty makes no attempt to identify nor recreate lost
# partition tables.

ECHO="/usr/bin/echo -e"

if [ ! -x /bin/uuid ]; then
    ${ECHO} /bin/uuid must be installed to proceed
    exit -1
fi


lsblk -p
${ECHO} "Mount Device ID ([/dev/sdb]): \c"
read dev_id

if [ ! -n "$dev_id" ]; then
    dev_id="/dev/sdb"
fi
if [ ! -b "$dev_id" ]; then
    ${ECHO} Device must be a block special device
    exit -1
fi

${ECHO}
${ECHO} "Note this only includes logic for single disk VGs"
${ECHO} "This procedure is destructive to non-PVs"
${ECHO} "You will be asked 3 times if you are sure you wish to proceed"
${ECHO}
${ECHO} "Are you sure you wish to proceed? Type 'Yes': \c"
read proceed
if [ "$proceed" != "Yes" ]; then
    exit
fi
${ECHO} "Are you sure you wish to proceed? Type 'Proceed': \c"
read proceed
if [ "$proceed" != "Proceed" ]; then
    exit
fi
${ECHO} "Are you sure you wish to proceed? Type 'Now': \c"
read proceed
if [ "$proceed" != "Now" ]; then
    exit
fi

${ECHO} 'You responded "Yes Proceed Now"'

# Get UUID
LUKS_UUID=`cryptsetup luksUUID $dev_id`

if [ -n "$LUKS_UUID" ]; then
    ${ECHO} LUKS_UUID=$LUKS_UUID

    cryptsetup status luks-$LUKS_UUID > /tmp/mount.$$
    RES=$?
    if [ $RES -ne 0 ]; then
        ${ECHO} Opening Luks Device
	cryptsetup luksOpen $dev_id luks-$LUKS_UUID
	RES=$?
	if [ $RES -ne 0 ]; then
            ${ECHO} Failed to perform luksOpen: $RES
	    rm -f /tmp/mount.$$
	    exit -$RES
	fi
        cryptsetup status luks-$LUKS_UUID > /tmp/mount.$$
    fi
    LUKS_TYPE=`grep type: /tmp/mount.$$ | awk '{print $2}'`
    LUKS_SIZE=`egrep 'size: .*sectors' /tmp/mount.$$ | awk '{print $2}'`

    echo LUKS_TYPE=$LUKS_TYPE
    echo LUKS_SIZE=$LUKS_SIZE

    rm -f /tmp/mount.$$

    # Check if in crypttab
    egrep -q "^luks-$LUKS_UUID " /etc/crypttab
    if [ $? -ne 0 ]; then
        ${ECHO} Adding to /etc/crypttab
        ${ECHO} "luks-$LUKS_UUID $dev_id -" >> /etc/crypttab
        ${ECHO} "Updating boot image: dracut -f"
        dracut -f
    fi

    RAW_DEV="/dev/mapper/luks-$LUKS_UUID"
    RAW_SIZE=$LUKS_SIZE
else
    ${ECHO} Device is not LUKS\'d
    RAW_DEV=$dev_id
    RAW_SIZE=`lsblk --nodeps -n -b -o SIZE $RAW_DEV`
    RAW_SIZE=$(($RAW_SIZE/512))
fi
echo RAW_DEV=$RAW_DEV
echo RAW_SIZE=$RAW_SIZE

${ECHO} "Need to know if this block device has a filesystem or LVM PV"
${ECHO} "Note this only includes logic for single disk VGs"

BCK_NAME=echo $RAW_DEV | sed 's"/"_"g'
${ECHO} "Backing up disk blocks"
dd if=$RAW_DEV of=$BCK_NAME bs=512 count=2048
if [ $? -ne 0 -o ! -r $BCK_NAME ]; then
    ${ECHO} "Backup failed.  aborting"
    exit -1
fi

lsblk -f -n -o FSTYPE

pvs $RAW_DEV
IS_PV=$?   # 0 = Yes, anything = no

if [ $IS_PV -ne 0 ]; then
    ${ECHO} "$RAW_DEV isn't labeled as a PV"

    ${ECHO} "Starting potentially destructive actions"
    ${ECHO} "pvcreate $RAW_DEV"
    pvcreate $RAW_DEV
    RES=$?
    if [ $RES -ne 0 ]; then
        ${ECHO} "pvcreate failed: $RES"
	exit -1
    fi
fi

PV_UUID=`pvdisplay $RAW_DEV | grep "PV UUID" | awk '{ print $3 }'`
${ECHO} PV_UUID=$PV_UUID

NEED_LV=0

PV_VG=`pvdisplay $RAW_DEV | grep "VG Name" | awk '{ print $3 }'`
if [ -n "$PV_VG" ]; then
    ${ECHO} "PV already has a volume group: $PV_VG"
    ${ECHO}
    ${ECHO} "Check and see if we have a logical volume"
    lvs $PV_VG
    RES=$?
    if [ $RES -eq 0 ]; then
        ${ECHO} "Good news, LV already exists"
	VG_NAME=$PV_VG
    else
        NEED_LV=1
    fi
else
    NEED_LV=1
fi

if [ $NEED_LV -eq 1 ]; then

    VG_NAMEx="vg_recovery_$$"
    ${ECHO} "Name the Volume Group - no spaces [$VG_NAMEx]: \c"
    read VG_NAME
    if [ ! -n "$VG_NAME" ]; then
        VG_NAME=$VG_NAMEx
    fi
    LV_NAMEx="lv_recovery_$$"
    ${ECHO} "Name the Logical Volume - no spaces [$LV_NAMEx]: \c"
    read LV_NAME
    if [ ! -n "$LV_NAME" ]; then
        LV_NAME=$LV_NAMEx
    fi

    VG_UUID=`uuid`
    LV_UUID=`uuid`

    # Create a backup file to attempt recovery
    DATE=`date +%s`
    EXTENTS=$((($RAW_SIZE-1)/8192))

    LVM_BCK=/tmp/bck.$$
    ${ECHO} 'contents = "Text Format Volume Group"' > $LVM_BCK
    ${ECHO} 'version = 1' >> $LVM_BCK
    ${ECHO} '' >> $LVM_BCK
    ${ECHO} "description = \"Created for recovery\"" >> $LVM_BCK
    ${ECHO} "creation_host = \"$HOSTNAME\""  >> $LVM_BCK
    ${ECHO} "creation_time = $DATE" >> $LVM_BCK
    ${ECHO} '' >> $LVM_BCK
    ${ECHO} "$VG_NAME {" >> $LVM_BCK
    ${ECHO} "  id = \"$VG_UUID\"" >> $LVM_BCK
    ${ECHO} "  seqno = 3" >> $LVM_BCK
    ${ECHO} "  format = \"lvm2\"" >> $LVM_BCK
    ${ECHO} '  status = ["RESIZEABLE", "READ", "WRITE"]' >> $LVM_BCK
    ${ECHO} '  flags = []' >> $LVM_BCK
    ${ECHO} '  extent_size = 8192              # 4 Megabytes' >> $LVM_BCK
    ${ECHO} '  max_lv = 0' >> $LVM_BCK
    ${ECHO} '  max_pv = 0' >> $LVM_BCK
    ${ECHO} '  metadata_copies = 0' >> $LVM_BCK
    ${ECHO} '' >> $LVM_BCK
    ${ECHO} '  physical_volumes {' >> $LVM_BCK
    ${ECHO} '' >> $LVM_BCK
    ${ECHO} '    pv0 {' >> $LVM_BCK
    ${ECHO} "      id = \"$PV_UUID\"" >> $LVM_BCK
    ${ECHO} "      device = \"$RAW_DEV\"        # Hint only" >> $LVM_BCK
    ${ECHO} '' >> $LVM_BCK
    ${ECHO} '      status = ["ALLOCATABLE"]' >> $LVM_BCK
    ${ECHO} '      flags = []' >> $LVM_BCK
    ${ECHO} "      dev_size = $RAW_SIZE" >> $LVM_BCK
    ${ECHO} '      pe_start = 2048' >> $LVM_BCK
    ${ECHO} "      pe_count = $EXTENTS" >> $LVM_BCK
    ${ECHO} '    }' >> $LVM_BCK
    ${ECHO} '  }' >> $LVM_BCK
    ${ECHO} '' >> $LVM_BCK
    ${ECHO} '  logical_volumes {' >> $LVM_BCK
    ${ECHO} '' >> $LVM_BCK
    ${ECHO} "    $LV_NAME {" >> $LVM_BCK
    ${ECHO} "            id = \"$LV_UUID\"" >> $LVM_BCK
    ${ECHO} '            status = ["READ", "WRITE", "VISIBLE"]' >> $LVM_BCK
    ${ECHO} '            flags = []' >> $LVM_BCK
    ${ECHO} "            creation_time = $DATE" >> $LVM_BCK
    ${ECHO} "            creation_host = \"$HOSTNAME\"" >> $LVM_BCK
    ${ECHO} '            segment_count = 1' >> $LVM_BCK
    ${ECHO} '' >> $LVM_BCK
    ${ECHO} '            segment1 {' >> $LVM_BCK
    ${ECHO} '                    start_extent = 0' >> $LVM_BCK
    ${ECHO} "                    extent_count = $EXTENTS" >> $LVM_BCK
    ${ECHO} '' >> $LVM_BCK
    ${ECHO} '                    type = "striped"' >> $LVM_BCK
    ${ECHO} '                    stripe_count = 1        # linear' >> $LVM_BCK
    ${ECHO} '' >> $LVM_BCK
    ${ECHO} '                    stripes = [' >> $LVM_BCK
    ${ECHO} '                            "pv0", 0' >> $LVM_BCK
    ${ECHO} '                    ]' >> $LVM_BCK
    ${ECHO} '            }' >> $LVM_BCK
    ${ECHO} '    }' >> $LVM_BCK
    ${ECHO} '  }' >> $LVM_BCK
    ${ECHO} '}' >> $LVM_BCK

    ${ECHO} "Attempting LVM restore"
    ${ECHO} "vgcfgrestore -f $LVM_BCK $VG_NAME"
    vgcfgrestore -f $LVM_BCK $VG_NAME
    RES=$?
    if [ $RES -ne 0 ]; then
        ${ECHO} Restore failed!
	exit -1
    fi
fi

${ECHO} vgchange -ay $VG_NAME
vgchange -ay $VG_NAME
RES=$?
if [ $RES -ne 0 ]; then
    ${ECHO} Failed to activate $VG_NAME
exit -1
fi

LV_DEV=/dev/`lvs --no-headings -o LV_fullname $VG_NAME | awk '{print $1}'`

lvscan -b --devices $RAW_DEV
RES=$?
if [ $RES -eq 0 ]; then
    ${ECHO} "Good news, LV is activated"
else
    ${ECHO} "Device failed to activate $VNAME : $RAW_DEV"
fi

${ECHO} Attempt fsck of LV
fsck -V -C $LV_DEV -- -f -n

${ECHO} You may need to manually mount now
${ECHO} Device is: $LV_DEV
