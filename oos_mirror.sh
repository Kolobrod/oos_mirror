#!/bin/bash

[ "${FLOCKER}" != "$0" ] && exec env FLOCKER="$0" flock -en "$0" "$0" "$@" || :	# Boilerplate code from man flock, ensure only one instance is running

VERSION='1.11'

echo_with_time()
	{
	local cur_time=$( date --rfc-3339=ns )
	echo "$cur_time $1"
	}

go_fail()
	{
	echo_with_time "$THIS_SCRIPT_NAME failed!"
	exit 1
	}

clear_once()
	{
	local dest="$1"
	if echo "$cleared" | fgrep -q "$1"; then
		echo_with_time 'Destination already cleared'
	else
		echo_with_time "Removing old results from $dest"
		rm -rf "$dest"; mkdir -p "$dest"	# Clearing directory using bash globbing could be slow or fail if there are many files
		cleared+=" $dest"
	fi
	}

test_ftp_url()	# lftp may hang on some ftp problems, like no connection
	{
	local url="$1"

	if ! echo "$url" | grep -q '^[[:blank:]]*ftp://[[:alnum:]]\+:[[:alnum:]]\+@[[:alnum:]\.]\+/.*[[:blank:]]*$'; then return 1; fi

	local login=$(	echo "$url" | sed 's|[[:blank:]]*ftp://\([^:]\+\):\([^@]\+\)@\([^/]\+\)\(/.*\)[[:blank:]]*|\1|' )
	local pass=$(	echo "$url" | sed 's|[[:blank:]]*ftp://\([^:]\+\):\([^@]\+\)@\([^/]\+\)\(/.*\)[[:blank:]]*|\2|' )
	local host=$(	echo "$url" | sed 's|[[:blank:]]*ftp://\([^:]\+\):\([^@]\+\)@\([^/]\+\)\(/.*\)[[:blank:]]*|\3|' )
	local dir=$(	echo "$url" | sed 's|[[:blank:]]*ftp://\([^:]\+\):\([^@]\+\)@\([^/]\+\)\(/.*\)[[:blank:]]*|\4|' )

	exec 3>&2 2>/dev/null
#	exec 6<>"/dev/tcp/$host/21" || { exec 2>&3 3>&-; return 2; }
	exec 6<>"/dev/tcp/$host/21" || { exec 2>&3 3>&-; echo_with_time 'Bash network support is disabled. Skipping ftp check.'; return 0; }

	read <&6
	if ! echo "${REPLY//$'\r'}" | grep -q '^220'; then exec 2>&3  3>&- 6>&-; return 3; fi	# 220 vsFTPd 3.0.2+ (ext.1) ready...

	echo -e "USER $login\r" >&6; read <&6
	if ! echo "${REPLY//$'\r'}" | grep -q '^331'; then exec 2>&3  3>&- 6>&-; return 4; fi	# 331 Please specify the password.

	echo -e "PASS $pass\r" >&6; read <&6
	if ! echo "${REPLY//$'\r'}" | grep -q '^230'; then exec 2>&3  3>&- 6>&-; return 5; fi	# 230 Login successful.

	echo -e "CWD $dir\r" >&6; read <&6
	if ! echo "${REPLY//$'\r'}" | grep -q '^250'; then exec 2>&3  3>&- 6>&-; return 6; fi	# 250 Directory successfully changed.

	echo -e "QUIT\r" >&6

	exec 2>&3  3>&- 6>&-
	return 0
	}

do_fz223()
	{
	echo_with_time 'Doing FZ223'

	# Todo: remove slashes
	if [ -z "$FZ223_BASE_URL" -o -z "$FZ223_REGIONS" -o -z "FZ223_FOLDERS" -o -z "$FZ223_RESULT_DIR" ]; then
		echo 'Not all required for FZ223 variables set: FZ223_BASE_URL, FZ223_REGIONS, FZ223_FOLDERS, FZ223_RESULT_DIR'
		return
	fi

	FZ223_TYPE_FOLDERS='explanation purchaseContract purchaseNotice purchaseProtocol purchaseRejection'
	FZ223_BASE_URL_NOPASS=$( echo "$FZ223_BASE_URL" | sed 's|//.*@|//|' )		# Removing login:password from url

	if [ "$FZ223_LEGACY_DIRS" == 'yes' ]; then
		legacy_dir='/daily'
	fi

	clear_once "$FZ223_RESULT_DIR"

	for down_folder in $FZ223_FOLDERS; do
		for region in $FZ223_REGIONS; do
			rm -rf "$ZIP_DIR"; mkdir -p "$ZIP_DIR"
			fz223_url="$FZ223_BASE_URL/$region/$down_folder/daily/"
			if ! test_ftp_url "$fz223_url"; then echo_with_time "Testing \"$FZ223_BASE_URL_NOPASS/$region/$down_folder/daily\" failed!"; break; fi
			echo_with_time "Downloading files from $FZ223_BASE_URL_NOPASS/$region/$down_folder/daily to $ZIP_DIR"
			lftp -c "open $fz223_url; mirror --newer-than now-${DOWNLOAD_DAYS_NEWER}days ./ $ZIP_DIR"
			chmod -R u+rw "$ZIP_DIR"
			zipfiles=$( /usr/bin/find "$ZIP_DIR" -type f -name '*.zip' )
			num_files=$( echo "$zipfiles" | sed '/^$/d' | wc -l )
			echo_with_time "Downloaded $num_files zip files"
			for zipfile in $zipfiles; do
				rm -rf "$XML_DIR"; mkdir -p "$XML_DIR"
				/usr/bin/unzip -j -o -d "$XML_DIR" "$zipfile"
				xmlfiles=$( /usr/bin/find "$XML_DIR" -type f -name '*.xml' )
				num_xml_files=$( echo "$xmlfiles" | sed '/^$/d' | wc -l )
				echo_with_time "$num_xml_files files unzipped"
				for xmlfile in $xmlfiles; do
					hash=$( md5sum "$xmlfile" )
					xmlfile_basename=$( basename "$xmlfile" )
					#sed 's|^.*/\([^/]*\)$|\1|;s|^\([^[:alpha:]]*_\)*\([[:alnum:]]\+\)_.*$|\2|'
					supposed_dir=$( echo -n "$xmlfile_basename" | sed 's|^\([^[:alpha:]]*_\)*\([[:alnum:]]\+\)_.*$|\2|' )
					newname=$( echo -n "$xmlfile_basename" | sed "s|\.xml|_${hash%% *}.xml|" )	# Renaming for ensure unical name
					dest_dir="$FZ223_RESULT_DIR/$supposed_dir$legacy_dir"
					for type_dir in $FZ223_TYPE_FOLDERS; do
						if [[ "X$supposed_dir" =~ "X$type_dir".* ]]; then
						dest_dir="$FZ223_RESULT_DIR/$type_dir$legacy_dir"
						break
						fi
					done
					mkdir -p "$dest_dir"
					mv "$xmlfile" "$dest_dir/$newname"
				done
				rm -rf "$XML_DIR"
			done
			rm -rf "$ZIP_DIR"
		done
	done
	echo_with_time 'FZ223 done'
	}

do_fz94()
	{
	echo_with_time 'Doing FZ94'

	if [ -z "$FZ94_BASE_URL" -o -z "$FZ94_REGIONS" -o -z "$FZ94_RESULT_DIR" ]; then
		echo 'Not all required for FZ94 variables set: FZ94_BASE_URL, FZ94_REGIONS, FZ94_RESULT_DIR'
		return
	fi

	FZ94_BASE_URL_NOPASS=$( echo "$FZ94_BASE_URL" | sed 's|//.*@|//|' )		# Removing login:password from url
	FZ94_SUBDIRS="${FZ94_SUBDIRS:-/}"						# Set FZ94_SUBDIRS to /, if it was not set in config

	clear_once "$FZ94_RESULT_DIR"

	for region in $FZ94_REGIONS; do
		rm -rf "$ZIP_DIR"; mkdir -p "$ZIP_DIR"
		if ! test_ftp_url "$FZ94_BASE_URL/$region"; then echo_with_time "Testing \"$FZ94_BASE_URL_NOPASS/$region\" failed!"; break; fi
		echo_with_time "Downloading files from $FZ94_BASE_URL_NOPASS/$region to $ZIP_DIR"
		for subdir in $FZ44_SUBDIRS; do
			echo_with_time "Downloading \"$subdir\" directory"
			lftp -c "open $FZ94_BASE_URL/$region/$subdir; mirror --newer-than now-${DOWNLOAD_DAYS_NEWER}days ./ $ZIP_DIR"
		done
		chmod -R u+rw "$ZIP_DIR"
		zipfiles=$( /usr/bin/find "${ZIP_DIR}" -type f -name '*.zip' )
		num_files=$( echo "$zipfiles" | sed '/^$/d' | wc -l )
		echo_with_time "Downloaded $num_files zip files"
		for zipfile in $zipfiles; do
			/usr/bin/unzip -j -o -d "${FZ94_RESULT_DIR}" "$zipfile"
			rm "$zipfile"
		done
	done
	rm -rf "$ZIP_DIR"

	echo_with_time 'FZ94 done'
	}

do_fz44()
	{
	echo_with_time 'Doing FZ44'

	if [ -z "$FZ44_BASE_URL" -o -z "$FZ44_REGIONS" -o -z "$FZ44_RESULT_DIR" ]; then
		echo 'Not all required for FZ44 variables set: FZ44_BASE_URL, FZ44_REGIONS, FZ44_RESULT_DIR'
		return
	fi

	FZ44_BASE_URL_NOPASS=$( echo "$FZ44_BASE_URL" | sed 's|//.*@|//|' )		# Removing login:password from url
	FZ44_SUBDIRS="${FZ44_SUBDIRS:-/}"						# Set FZ44_SUBDIRS to /, if it was not set in config

	clear_once "$FZ44_RESULT_DIR"

	for region in $FZ44_REGIONS; do
		rm -rf "$ZIP_DIR"; mkdir -p "$ZIP_DIR"
		if ! test_ftp_url "$FZ44_BASE_URL/$region"; then echo_with_time "Testing \"$FZ44_BASE_URL_NOPASS/$region\" failed!"; break; fi
		echo_with_time "Downloading files from $FZ44_BASE_URL_NOPASS/$region to $ZIP_DIR"
		for subdir in $FZ44_SUBDIRS; do
			echo_with_time "Downloading \"$subdir\" directory"
			lftp -c "open $FZ44_BASE_URL/$region/$subdir; mirror --newer-than now-${DOWNLOAD_DAYS_NEWER}days ./ $ZIP_DIR"
		done
		chmod -R u+rw "$ZIP_DIR"
		zipfiles=$( /usr/bin/find "${ZIP_DIR}" -type f -name '*.zip' )
		num_files=$( echo "$zipfiles" | sed '/^$/d' | wc -l )
		echo_with_time "Downloaded $num_files zip files"
		for zipfile in $zipfiles; do
			/usr/bin/unzip -j -o -d "${FZ44_RESULT_DIR}" "$zipfile"
			rm "$zipfile"
		done
	done
	rm -rf "$ZIP_DIR"

	echo_with_time 'FZ44 done'
	}

do_nsi()
	{
	echo_with_time 'Doing NSI'

	if [ -z "$NSI_BASE_URL" -o -z "NSI_FOLDERS" -o -z "$NSI_RESULT_DIR" ]; then
		echo 'Not all required for NSI variables set: NSI_BASE_URL, NSI_FOLDERS, NSI_RESULT_DIR'
		return
	fi

	NSI_BASE_URL_NOPASS=$( echo "$NSI_BASE_URL" | sed 's|//.*@|//|' )		# Removing login:password from url

	if [ "$NSI_LEGACY_DIRS" == 'yes' ]; then
		legacy_dir='/daily'
	fi

	clear_once "$NSI_RESULT_DIR"

	for folder in $NSI_FOLDERS; do
		rm -rf "$ZIP_DIR"; mkdir -p "$ZIP_DIR"
		nsi_url="$NSI_BASE_URL/$folder/daily"
		if ! test_ftp_url "$nsi_url"; then echo_with_time "Testing \"$NSI_BASE_URL_NOPASS/$folder/daily\" failed!"; break; fi
		echo "Downloading files from $NSI_BASE_URL_NOPASS/$folder/daily to $ZIP_DIR"
		lftp -c "open $nsi_url; mirror --newer-than now-${DOWNLOAD_DAYS_NEWER}days ./ $ZIP_DIR"
		chmod -R u+rw "$ZIP_DIR"
		zipfiles=$( /usr/bin/find "$ZIP_DIR" -type f -name '*.zip' )
		num_files=$( echo "$zipfiles" | sed '/^$/d' | wc -l )
		echo "Downloaded $num_files files"
		for zipfile in $zipfiles; do
			rm -rf "$XML_DIR"; mkdir -p "$XML_DIR"
			/usr/bin/unzip -j -o -d "$XML_DIR" "$zipfile"
			xmlfiles=$( /usr/bin/find "$XML_DIR" -type f -name '*.xml' )
			num_xml_files=$( echo "$xmlfiles" | sed '/^$/d' | wc -l )
			echo_with_time "$num_xml_files files unzipped"
			for xmlfile in $xmlfiles; do
				hash=$( md5sum "$xmlfile" )
				xmlfile_basename=$( basename "$xmlfile" )
				supposed_dir=$( echo -n "$xmlfile_basename" | sed 's|^\([^[:alpha:]]*_\)*\([[:alnum:]]\+\)_.*$|\2|' )
				newname=$( echo -n "$xmlfile_basename" | sed "s|\.xml|_${hash%% *}.xml|" )	# Renaming for ensure unical name
				dest_dir="$NSI_RESULT_DIR/$supposed_dir$legacy_dir"
				mkdir -p "$dest_dir"
				mv "$xmlfile" "$dest_dir/$newname"
			done
			rm -rf "$XML_DIR"
		done
		rm -rf "$ZIP_DIR"
	done
	echo_with_time 'NSI done'
	}

if ! which 'unzip' >/dev/null 2>&1; then
        echo 'Expected zip program not found!' >&2
        exit 1
fi
if ! which 'lftp' >/dev/null 2>&1; then
        echo 'Expected lftp tool not found!' >&2
        exit 1
fi

SCRIPT_FILE_NAME=$( basename $0 )
SCRIPT_DIR_NAME=$( dirname $0 )
THIS_SCRIPT_NAME="${SCRIPT_FILE_NAME%.sh}"
CONFIG_FILE_NAME="${SCRIPT_DIR_NAME}/${THIS_SCRIPT_NAME}.config"
DATE_POSTFIX=$( date '+%Y_%m_%d_%H_%M_%S' )

if [ ! -r "$CONFIG_FILE_NAME" ]; then
	echo "No readable config file $CONFIG_FILE_NAME found!" >&2
	exit 1
fi
source "$CONFIG_FILE_NAME"	# TODO: set default values in case of old copied configs

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${THIS_SCRIPT_NAME}_${DATE_POSTFIX}.log"

exec 1>>"$LOG_FILE" 2>&1		# Redirect all output to log

echo_with_time "$THIS_SCRIPT_NAME version $VERSION started ----------------"
echo_with_time "Will download files for recent $DOWNLOAD_DAYS_NEWER days"

if [ -z "$LOG_DIR" -o -z "$DOWNLOAD_DAYS_NEWER" ]; then
	echo 'Not all required common variables set: LOG_DIR, DOWNLOAD_DAYS_NEWER'
	go_fail
fi

CONFIG_TEMP_DIR="${CONFIG_TEMP_DIR:-/tmp}"
TEMP_DIR="$CONFIG_TEMP_DIR/$THIS_SCRIPT_NAME"
ZIP_DIR="$TEMP_DIR/zip"
XML_DIR="$TEMP_DIR/xml"

if [ "$DO_FZ223" == 'yes' ]; then do_fz223; fi
if [ "$DO_FZ94" == 'yes' ]; then do_fz94; fi
if [ "$DO_FZ44" == 'yes' ]; then do_fz44; fi
if [ "$DO_NSI" == 'yes' ]; then do_nsi; fi

rm -rf "$TEMP_DIR"
echo_with_time "$THIS_SCRIPT_NAME completed"
