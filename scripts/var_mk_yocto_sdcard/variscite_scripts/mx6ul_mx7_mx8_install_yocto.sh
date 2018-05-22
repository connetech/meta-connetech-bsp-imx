#!/bin/bash

# Installs Yocto to NAND/eMMC
set -e

. /usr/bin/echos.sh

IMGS_PATH=/opt/images/Yocto
KERNEL_IMAGE=zImage
KERNEL_DTB=""
STORAGE_DEV=""
BOOTLOAD_RESERVE_SIZE=4
PART1_SIZE=8

if [[ $EUID != 0 ]] ; then
	red_bold_echo "This script must be run with super-user privileges"
	exit 1
fi

check_images()
{
	if [[ ! -f $IMGS_PATH/$UBOOT_IMAGE ]] ; then
		red_bold_echo "ERROR: \"$IMGS_PATH/$UBOOT_IMAGE\" does not exist"
		exit 1
	fi

	if [[ $IS_SPL == "true" &&  ! -f $IMGS_PATH/$SPL_IMAGE ]] ; then
		red_bold_echo "ERROR: \"$IMGS_PATH/$SPL_IMAGE\" does not exist"
		exit 1
	fi

	if [[ ! -f $IMGS_PATH/$KERNEL_IMAGE ]] ; then
		red_bold_echo "ERROR: \"$IMGS_PATH/$KERNEL_IMAGE\" does not exist"
		exit 1
	fi

	if [[ $STORAGE_DEV == "nand" && ! -f $IMGS_PATH/$KERNEL_DTB ]] ; then
		red_bold_echo "ERROR: \"$IMGS_PATH/$KERNEL_DTB\" does not exist"
		exit 1
	fi

	if [[ ! -f $IMGS_PATH/$ROOTFS_IMAGE ]] ; then
		red_bold_echo "ERROR: \"$IMGS_PATH/$ROOTFS_IMAGE\" does not exist"
		exit 1
	fi
}

set_fw_utils_to_emmc()
{
	# Adjust u-boot-fw-utils for eMMC on the SD card
	if [[ `readlink /sbin/fw_printenv` != "/sbin/fw_printenv-mmc" ]]; then
		ln -sf /sbin/fw_printenv-mmc /sbin/fw_printenv
	fi
	sed -i "/mtd/ s/^#*/#/" /etc/fw_env.config
	sed -i "s/#*\/dev\/mmcblk./\/dev\/${block}/" /etc/fw_env.config
}

set_fw_utils_to_nand()
{
	# Adjust u-boot-fw-utils for NAND flash on the SD card
	if [[ `readlink /sbin/fw_printenv` != "/sbin/fw_printenv-nand" ]]; then
		ln -sf /sbin/fw_printenv-nand /sbin/fw_printenv
	fi
	sed -i "/mmcblk/ s/^#*/#/" /etc/fw_env.config
	sed -i "s/#*\/dev\/mtd/\/dev\/mtd/" /etc/fw_env.config
}

install_bootloader_to_nand()
{
	echo
	blue_underlined_bold_echo "Installing booloader"

	flash_erase /dev/mtd0 0 0 2> /dev/null
	if [[ $IS_SPL == "true" ]] ; then
		kobs-ng init -x $IMGS_PATH/$SPL_IMAGE --search_exponent=1 -v > /dev/null

		flash_erase /dev/mtd1 0 0 2> /dev/null
		nandwrite -p /dev/mtd1 $IMGS_PATH/$UBOOT_IMAGE
	else
		kobs-ng init -x $IMGS_PATH/$UBOOT_IMAGE --search_exponent=1 -v > /dev/null
	fi

	flash_erase /dev/mtd2 0 0 2> /dev/null
	sync
}

install_kernel_to_nand()
{
	echo
	blue_underlined_bold_echo "Installing kernel"

	flash_erase /dev/mtd3 0 0 2> /dev/null
	nandwrite -p /dev/mtd3 $IMGS_PATH/$KERNEL_IMAGE > /dev/null
	nandwrite -p /dev/mtd3 -s 0x7e0000 $IMGS_PATH/$KERNEL_DTB > /dev/null
	sync
}

install_rootfs_to_nand()
{
	echo
	blue_underlined_bold_echo "Installing UBI rootfs"

	ubiformat /dev/mtd4 -f $IMGS_PATH/$ROOTFS_IMAGE -y
	sync
}

delete_emmc()
{
	echo
	blue_underlined_bold_echo "Deleting current partitions"

	for ((i=0; i<=10; i++))
	do
		if [[ -e ${node}${part}${i} ]] ; then
			dd if=/dev/zero of=${node}${part}${i} bs=1024 count=1024 2> /dev/null || true
		fi
	done
	sync

	((echo d; echo 1; echo d; echo 2; echo d; echo 3; echo d; echo w) | fdisk $node &> /dev/null) || true
	sync

	dd if=/dev/zero of=$node bs=1M count=${BOOTLOAD_RESERVE_SIZE}

	sync; sleep 1
}

create_emmc_parts()
{
	echo
	blue_underlined_bold_echo "Creating new partitions"

	if [[ $BOARD != "mx8m" ]]; then
		SECT_SIZE_BYTES=`cat /sys/block/${block}/queue/hw_sector_size`
		PART1_FIRST_SECT=$(($BOOTLOAD_RESERVE_SIZE * 1024 * 1024 / $SECT_SIZE_BYTES))
		PART2_FIRST_SECT=$((($BOOTLOAD_RESERVE_SIZE + $PART1_SIZE) * 1024 * 1024 / $SECT_SIZE_BYTES))
		PART1_LAST_SECT=$(($PART2_FIRST_SECT - 1))

		(echo n; echo p; echo $bootpart; echo $PART1_FIRST_SECT; echo $PART1_LAST_SECT; echo t; echo c; \
		 echo n; echo p; echo $rootfspart; echo $PART2_FIRST_SECT; echo; \
	 	echo p; echo w) | fdisk -u $node > /dev/null
	else

		SECT_SIZE_BYTES=`cat /sys/block/${block}/queue/hw_sector_size`
		PART1_FIRST_SECT=$(($BOOTLOAD_RESERVE_SIZE * 1024 * 1024 / $SECT_SIZE_BYTES))

		(echo n; echo p; echo $rootfspart; echo $PART1_FIRST_SECT; echo; \
	 	echo p; echo w) | fdisk -u $node > /dev/null
	fi

	sync; sleep 1
	fdisk -u -l $node
}

create_emmc_swupdate_parts()
{
	echo
	blue_underlined_bold_echo "Creating new partitions"
	TOTAL_SECTORS=`cat /sys/class/block/${block}/size`
	SECT_SIZE_BYTES=`cat /sys/block/${block}/queue/hw_sector_size`

	BOOTLOAD_RESERVE_SIZE_BYTES=$((BOOTLOAD_RESERVE_SIZE * 1024 * 1024))
	DATA_SIZE_BYTES=$((DATA_SIZE * 1024 * 1024))
	DATA_PART_SIZE=$((DATA_SIZE_BYTES / SECT_SIZE_BYTES))
	ROOTFS1_PART_SIZE=$((( TOTAL_SECTORS - ROOTFS1_PART_START - DATA_PART_SIZE ) / 2))
	ROOTFS2_PART_SIZE=$ROOTFS1_PART_SIZE

	ROOTFS1_PART_START=$((BOOTLOAD_RESERVE_SIZE_BYTES / SECT_SIZE_BYTES))
	ROOTFS2_PART_START=$((ROOTFS1_PART_START + ROOTFS1_PART_SIZE))
	DATA_PART_START=$((ROOTFS2_PART_START + ROOTFS2_PART_SIZE))

	ROOTFS1_PART_END=$((ROOTFS2_PART_START - 1))
	ROOTFS2_PART_END=$((DATA_PART_START - 1))

	(echo n; echo p; echo $rootfspart;  echo $ROOTFS1_PART_START; echo $ROOTFS1_PART_END; \
	 echo n; echo p; echo $rootfs2part; echo $ROOTFS2_PART_START; echo $ROOTFS2_PART_END; \
	 echo n; echo p; echo $datapart;    echo $DATA_PART_START; echo; \
	 echo p; echo w) | fdisk -u $node > /dev/null

	sync; sleep 1
	fdisk -u -l $node
}

format_emmc_parts()
{
	echo
	blue_underlined_bold_echo "Formatting partitions"

	if [[ $swupdate == 0 ]] ; then
		if [[ $BOARD != "mx8m" ]]; then
			mkfs.vfat ${node}${part}${bootpart} -n ${FAT_VOLNAME}
			mkfs.ext4 ${node}${part}${rootfspart} -L rootfs
		else
			mkfs.ext4 ${node}${part}${rootfspart} -L rootfs
		fi
	elif [[ $swupdate == 1 ]] ; then
		mkfs.ext4 ${node}${part}${rootfspart}  -L rootfs1
		mkfs.ext4 ${node}${part}${rootfs2part} -L rootfs2
		mkfs.ext4 ${node}${part}${datapart}    -L data
	fi
	sync; sleep 1
}

install_bootloader_to_emmc()
{
	echo
	blue_underlined_bold_echo "Installing booloader"

	if [[ $IS_SPL == "true" ]] ; then
		dd if=${IMGS_PATH}/${SPL_IMAGE} of=${node} bs=1K seek=1; sync
		dd if=${IMGS_PATH}/${UBOOT_IMAGE} of=${node} bs=1K seek=69; sync
	elif [[ $BOARD != "mx8m" ]]; then
		dd if=${IMGS_PATH}/${UBOOT_IMAGE} of=${node} bs=1K seek=1; sync
	else
		dd if=${IMGS_PATH}/${UBOOT_IMAGE} of=${node} bs=1K seek=33; sync
	fi

	if [[ $VARSOMMX7_VARIANT == "-m4" || $swupdate == 1 ]] ; then
		echo
		echo "Setting U-Boot enviroment variables"
		set_fw_utils_to_emmc

		if [[ $VARSOMMX7_VARIANT == "-m4" ]] ; then
			fw_setenv use_m4 yes  2> /dev/null
		fi

		if [[ $swupdate == 1 ]] ; then
			fw_setenv mmcrootpart 1  2> /dev/null
			fw_setenv bootdir /boot
		fi
	fi
}

install_kernel_to_emmc()
{
	echo
	blue_underlined_bold_echo "Installing kernel to BOOT partition"

	mkdir -p ${mountdir_prefix}${bootpart}
	mount ${node}${part}${bootpart}		${mountdir_prefix}${bootpart}
	if [[ $BOARD = "mx8m" ]]; then
           rm -f ${mountdir_prefix}${bootpart}/${bootdir}/*
	fi
	cd ${IMGS_PATH}
	cp -av ${KERNEL_DTBS}	${mountdir_prefix}${bootpart}/${bootdir}
	cp -av ${KERNEL_IMAGE}	${mountdir_prefix}${bootpart}/${bootdir}
	cd - >/dev/null
	sync
	if [[ $BOARD = "mx8m" ]]; then
		(cd ${mountdir_prefix}${bootpart}/${bootdir}; ln -fs imx8m-var-dart-emmc-wifi-${MX8M_DISPLAY}.dtb imx8m-var-dart.dtb)
	fi

	umount ${node}${part}${bootpart}
}

install_rootfs_to_emmc()
{
	echo
	blue_underlined_bold_echo "Installing rootfs"

	mkdir -p ${mountdir_prefix}${rootfspart}
	mount ${node}${part}${rootfspart} ${mountdir_prefix}${rootfspart}

	printf "Extracting files"
	tar --warning=no-timestamp -xpf ${IMGS_PATH}/${ROOTFS_IMAGE} -C ${mountdir_prefix}${rootfspart} --checkpoint=.1200

	# Adjust u-boot-fw-utils for eMMC on the installed rootfs
	if [[ $BOARD != "mx8m" ]]; then
		rm ${mountdir_prefix}${rootfspart}/sbin/fw_printenv-nand
		mv ${mountdir_prefix}${rootfspart}/sbin/fw_printenv-mmc ${mountdir_prefix}${rootfspart}/sbin/fw_printenv
		sed -i "/mtd/ s/^#*/#/" ${mountdir_prefix}${rootfspart}/etc/fw_env.config
		sed -i "s/#*\/dev\/mmcblk./\/dev\/${block}/" ${mountdir_prefix}${rootfspart}/etc/fw_env.config
	fi

	if [[ $BOARD = "mx8m" ]]; then
		cp ${mountdir_prefix}${rootfspart}/etc/wifi/blacklist.conf ${mountdir_prefix}${rootfspart}/etc/modprobe.d
	fi

	echo
	sync
	umount ${node}${part}${rootfspart}
}

usage()
{
	echo
	echo "This script installs Yocto on the SOM's internal storage device"
	echo
	echo " Usage: $0 OPTIONS"
	echo
	echo " OPTIONS:"
	echo " -b <mx6ul|mx6ul5g|mx6ull|mx6ull5g|mx7|mx8m>	Board model (DART-6UL/DART-6UL-5G/DART-6ULL/DART-6ULL-5G/VAR-SOM-MX7/DART-MX8M) - optional, autodetected if not provided."
	echo " -r <nand|emmc>		storage device (NAND flash/eMMC) - optional, autodetected if not provided."
	echo " -v <wifi|sd>		DART-6UL Variant (WiFi/SD card) - mandatory in case of DART-6UL with NAND flash; ignored otherwise."
	echo " -m			VAR-SOM-MX7 optional Cortex-M4 support; ignored in case of DART-6UL."
	echo " -u			create two rootfs partitions (for swUpdate double-copy) - ignored in case of NAND storage device."
	echo " -d <hdmi|dcss-lvds>	display type for DART-MX8M - optional, defaults to dcss-lvds if not provided"
	echo
}

finish()
{
	echo
	blue_bold_echo "Yocto installed successfully"
	exit 0
}


blue_underlined_bold_echo "*** Variscite MX6UL/MX6ULL/MX7/MX8M Yocto eMMC/NAND Recovery ***"
echo

VARSOMMX7_VARIANT=""
swupdate=0
MX8M_DISPLAY="dcss-lvds"

SOC=`cat /sys/bus/soc/devices/soc0/soc_id`
if [[ $SOC == i.MX6UL* ]] ; then
	BOARD=mx6ul
	if [[ $SOC == i.MX6ULL ]] ; then
		BOARD+=l
	fi
	SOM_INFO=`i2cget -y 1 0x51 0xfd`
	if [[ $(($(($SOM_INFO >> 3)) & 0x3)) == 1 ]] ; then
		BOARD+=5g
	fi

	if [[ -d /sys/bus/platform/devices/1806000.gpmi-nand ]] ; then
		STORAGE_DEV=nand
	else
		STORAGE_DEV=emmc
	fi
elif [[ $SOC == i.MX7D ]] ; then
	BOARD=mx7

	if [[ -d /sys/bus/platform/devices/33002000.gpmi-nand ]] ; then
		STORAGE_DEV=nand
	else
		STORAGE_DEV=emmc
	fi
elif [[ $SOC == i.MX8M* ]] ; then
	BOARD=mx8m
	STORAGE_DEV=emmc
	BOOTLOAD_RESERVE_SIZE=8
fi

while getopts :b:d:r:v:mu OPTION;
do
	case $OPTION in
	b)
		BOARD=$OPTARG
		;;
	r)
		STORAGE_DEV=$OPTARG
		;;
	v)
		DART6UL_VARIANT=$OPTARG
		;;
	m)
		VARSOMMX7_VARIANT=-m4
		;;
	u)
		swupdate=1
		;;
	d)
		MX8M_DISPLAY=$OPTARG
		;;
	*)
		usage
		exit 1
		;;
	esac
done

STR=""

if [[ $BOARD == "mx6ul" ]] ; then
	STR="DART-6UL (i.MX6UL)"
	IS_SPL=true
elif [[ $BOARD == "mx6ull" ]] ; then
	STR="DART-6UL (i.MX6ULL)"
	IS_SPL=true
elif [[ $BOARD == "mx6ul5g" ]] ; then
	STR="DART-6UL-5G (i.MX6UL)"
	IS_SPL=true
elif [[ $BOARD == "mx6ull5g" ]] ; then
	STR="DART-6UL-5G (i.MX6ULL)"
	IS_SPL=true
elif [[ $BOARD == "mx7" ]] ; then
	STR="VAR-SOM-MX7"
	IS_SPL=false
elif [[ $BOARD == "mx8m" ]] ; then
	STR="DART-MX8M"
	IS_SPL=false
	if [[ $swupdate == "1" ]]; then
		echo "swupdate is currently not supported on DART-MX8M"
		exit 1
	fi
	if [[ $MX8M_DISPLAY != "hdmi" ]] && [[ $MX8M_DISPLAY != "dcss-lvds" ]]; then
		echo "Invalid display, should be hdmi or dcss-lvds"
		exit 1
	fi
else
	usage
	exit 1
fi

printf "Board: "
blue_bold_echo $STR

if [[ $STORAGE_DEV == "nand" ]] ; then
	STR="NAND"
	ROOTFS_IMAGE=rootfs.ubi
elif [[ $STORAGE_DEV == "emmc" ]] ; then
	STR="eMMC"
	ROOTFS_IMAGE=rootfs.tar.gz
else
	usage
	exit 1
fi

printf "Installing to internal storage device: "
blue_bold_echo $STR

if [[ $BOARD == mx6ul* ]] ; then
	if [[ $STORAGE_DEV == "nand" ]] ; then
		if [[ $DART6UL_VARIANT == "wifi" ]] ; then
			STR="WiFi (no SD card)"
		elif [[ $DART6UL_VARIANT == "sd" ]] ; then
			STR="SD card (no WiFi)"
		else
			usage
			exit 1
		fi
		printf "With support for:  "
		blue_bold_echo "$STR"
	fi
fi

if [[ $STORAGE_DEV == "nand" ]] ; then
	if [[ $BOARD == mx6ul* ]] ; then
		SPL_IMAGE=SPL-nand
		UBOOT_IMAGE=u-boot.img-nand
		if [[ $BOARD == "mx6ul" ]] ; then
			if [[ $DART6UL_VARIANT == "wifi" ]] ; then
				KERNEL_DTB=imx6ul-var-dart-nand_wifi.dtb
			elif [[ $DART6UL_VARIANT == "sd" ]] ; then
				KERNEL_DTB=imx6ul-var-dart-sd_nand.dtb
			fi
		elif [[ $BOARD == "mx6ull" ]] ; then
			if [[ $DART6UL_VARIANT == "wifi" ]] ; then
				KERNEL_DTB=imx6ull-var-dart-nand_wifi.dtb
			elif [[ $DART6UL_VARIANT == "sd" ]] ; then
				KERNEL_DTB=imx6ull-var-dart-sd_nand.dtb
			fi
		elif [[ $BOARD == "mx6ul5g" ]] ; then
			if [[ $DART6UL_VARIANT == "wifi" ]] ; then
				KERNEL_DTB=imx6ul-var-dart-5g-nand_wifi.dtb
			elif [[ $DART6UL_VARIANT == "sd" ]] ; then
				KERNEL_DTB=imx6ul-var-dart-sd_nand.dtb
			fi
		elif [[ $BOARD == "mx6ull5g" ]] ; then
			if [[ $DART6UL_VARIANT == "wifi" ]] ; then
				KERNEL_DTB=imx6ull-var-dart-5g-nand_wifi.dtb
			elif [[ $DART6UL_VARIANT == "sd" ]] ; then
				KERNEL_DTB=imx6ull-var-dart-sd_nand.dtb
			fi
		fi
	elif [[ $BOARD == "mx7" ]] ; then
		UBOOT_IMAGE=u-boot.imx-nand
		KERNEL_DTB=imx7d-var-som-nand${VARSOMMX7_VARIANT}.dtb
	fi

	printf "Installing Device Tree file: "
	blue_bold_echo $KERNEL_DTB

	if [[ ! -e /dev/mtd0 ]] ; then
		red_bold_echo "ERROR: Can't find NAND flash device."
		red_bold_echo "Please verify you are using the correct options for your SOM."
		exit 1
	fi

	check_images
	install_bootloader_to_nand
	install_kernel_to_nand
	install_rootfs_to_nand
elif [[ $STORAGE_DEV == "emmc" ]] ; then
	if [[ $swupdate == 1 ]] ; then
		blue_bold_echo "Creating two rootfs partitions"
	fi

	if [[ $BOARD == mx6ul* ]] ; then
		block=mmcblk1
		SPL_IMAGE=SPL-sd
		UBOOT_IMAGE=u-boot.img-sd
		if [[ $BOARD == "mx6ul" || $BOARD == "mx6ul5g" ]] ; then
			KERNEL_DTBS="imx6ul-var-dart-emmc_wifi.dtb
				     imx6ul-var-dart-5g-emmc_wifi.dtb
				     imx6ul-var-dart-sd_emmc.dtb"
			FAT_VOLNAME=BOOT-VAR6UL
		elif [[ $BOARD == "mx6ull" || $BOARD == "mx6ull5g" ]] ; then
			KERNEL_DTBS="imx6ull-var-dart-emmc_wifi.dtb
				     imx6ull-var-dart-5g-emmc_wifi.dtb
				     imx6ull-var-dart-sd_emmc.dtb"
			FAT_VOLNAME=BOOT-VAR6ULL
		fi
	elif [[ $BOARD == "mx7" ]] ; then
		block=mmcblk2
		UBOOT_IMAGE=u-boot.imx-sd
		KERNEL_DTBS=imx7d-var-som-emmc*.dtb
		FAT_VOLNAME=BOOT-VARMX7
	elif [[ $BOARD == "mx8m" ]] ; then
		block=mmcblk0
		UBOOT_IMAGE=imx-boot-sd.bin
		KERNEL_IMAGE=Image.gz
		KERNEL_DTBS=imx8m-var-dart*.dtb
	fi
	node=/dev/${block}
	if [[ ! -b $node ]] ; then
		red_bold_echo "ERROR: Can't find eMMC device ($node)."
		red_bold_echo "Please verify you are using the correct options for your SOM."
		exit 1
	fi
	part=p
	mountdir_prefix=/run/media/${block}${part}

	if [[ $swupdate == 0 ]] ; then
		if [[ $BOARD != "mx8m" ]]; then
			bootpart=1
			rootfspart=2
			bootdir=/
		else
			bootpart=1
			rootfspart=1
			bootdir=/boot
		fi			
	elif [[ $swupdate == 1 ]] ; then
		bootpart=none
		rootfspart=1
		rootfs2part=2
		datapart=3

		DATA_SIZE=200
	fi

	check_images
	umount ${node}${part}*  2> /dev/null || true
	delete_emmc
	if [[ $swupdate == 0 ]] ; then
		create_emmc_parts
	elif [[ $swupdate == 1 ]] ; then
		create_emmc_swupdate_parts
	fi
	format_emmc_parts
	install_bootloader_to_emmc
	install_rootfs_to_emmc

	if [[ $swupdate == 0 ]] ; then
		install_kernel_to_emmc
	fi
fi

finish
