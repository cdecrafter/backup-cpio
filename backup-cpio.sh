#!/bin/sh
#
# backup-cpio version 1.0 - converted to use cpio instead of afio
# Copyright (C) 2025 Jörgen Johansson
#
#################################################################################
#
# backup-cpio - backup directories to files using cpio
#
#################################################################################
# backup-afio version 0.93 - fixed some issues with the file not properly running
# and made changes to support POSIX compliance copyright 2009 Antonio Arredondo, 
# and distributed under the terms of the GNU GPL license, available at 
# http://www.gnu.org/licenses/gpl.html
#
#################################################################################
#
# backup-afio version 0.92 - backup stuff in a robust way using afio
# This software is copyright 2005 Daniel M. Webb, and distributed under the
# terms of the GNU GPL license, available at http://www.gnu.org/licenses/gpl.html
THIS=backup-cpio
PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin
DATE_STRING=$(date +%F.%H-%M)
LOG_DIR=$(pwd)
LOG_FILE=$LOG_DIR/backup-cpio.$DATE_STRING.log
STDERR_LOG=$LOG_DIR/backup-cpio.$DATE_STRING.stderr
SPLIT_SUFFIX_LENGTH=3

die () {
  echo "$THIS: Fatal error: $*"
  exit 1
}

short_help() {
    cat <<END_OF_SHORT_HELP
$THIS - backup directories to files using cpio

usage:
  $THIS create [options] <backup directory> <archive file>
  $THIS restore [options] <restore directory> <archive file>
  $THIS verify [options] <backup directory> <archive file>
  $THIS list <archive file>

Options:
  -h    Full help
  -e    Filter files through GPG public key encryption
  -r    Set GPG recipient (same as gpg -r option)
  -z    Filter files through gzip compression
  -b    Filter files through bzip2 compression
  -k    Allow starting in the middle of an archive
  -x    Cross filesystem boundaries (default is to not cross)
  -s <split bytes> Split archive every <split-bytes> bytes
  -l <filelist generating program> to output filenames for cpio
  -y <pattern> Only process filenames matching <pattern>
  -Y <pattern> Exclude filenames matching <pattern>
  -w <file> Treat each line in <file> as a -y pattern
  -W <file> Treat each line in <file> as a -Y pattern
END_OF_SHORT_HELP
}

long_help() {
    short_help
    cat <<END_OF_LONG_HELP
See the cpio man page for more info. Only one of -e, -z, or -b may be used.

Encryption is supported via gpg, while compression is handled by gzip or bzip2.

Examples:

$ $THIS create -b -s 600m /home/me /tmp/backup.bz2.cpio
  Create a set of archives in /tmp/: backup.bz2.cpio.000, backup.bz2.cpio.001, etc.

$ $THIS create -e -r files@bob.net . ./f.gpg.cpio
  Create an encrypted archive of the current directory.

$ $THIS restore -e /tmp/test f.gpg.cpio
  Restore (extract) the encrypted archive f.gpg.cpio into /tmp/test.

END_OF_LONG_HELP
}

if [ "$1" = -h ]; then
    long_help
    exit 1
elif [ -z "$2" ]; then
    short_help
    exit 1
fi

COMMAND=$1
shift

# ================ Options processing ================
GPG_RECIPIENT=""
COMPRESS=false
K_OPTION=""
CROSS_FILESYSTEM_BOUNDARIES=" -xdev "  # Tell find not to cross filesystem boundaries
INCLUDE_PATTERN_FILE=""
IGNORE_PATTERN_FILE=""
INCLUDE_PATTERN=""
IGNORE_PATTERN=""
SPLIT_SIZE=""
FIND_PIPE=""

while getopts er:zbkxl:s:w:W:y:Y: opt
do
  case $opt in
    e) COMPRESS=gpg;;
    r) GPG_RECIPIENT=$OPTARG;;
    z) COMPRESS=gzip;;
    b) COMPRESS=bzip2;;
    k) K_OPTION="-k";;
    x) CROSS_FILESYSTEM_BOUNDARIES="";;
    l) FIND_PIPE=$OPTARG;;
    s) SPLIT_SIZE=$OPTARG;;
    w) INCLUDE_PATTERN_FILE="-w $OPTARG";;
    W) IGNORE_PATTERN_FILE="-W $OPTARG";;
    y) INCLUDE_PATTERN="$INCLUDE_PATTERN -y $OPTARG";;
    Y) IGNORE_PATTERN="$IGNORE_PATTERN -Y $OPTARG";;
  esac
done

shift `expr $OPTIND - 1`

# Set filelist generator to default if not specified
if [ -z "$FIND_PIPE" ]; then
    FIND_PIPE="find . $CROSS_FILESYSTEM_BOUNDARIES -print0"
fi

# ================ Compression options ================
FILTER_COMMAND=""
if [ $COMPRESS = gzip ]; then
  FILTER_COMMAND="gzip"
elif [ $COMPRESS = bzip2 ]; then
  FILTER_COMMAND="bzip2"
elif [ $COMPRESS = gpg ]; then
    [ -z "$(which gpg)" ] && die "encryption program gpg not found"
    if [ $COMMAND = "create" ]; then
        [ -z "$GPG_RECIPIENT" ] && die "GPG recipient must be set with -r option"
        FILTER_COMMAND="gpg --batch --quiet --encrypt --recipient $GPG_RECIPIENT"
    else
        FILTER_COMMAND="gpg --batch --quiet --decrypt"
    fi
fi

# ================ File and directory ================
if [ $COMMAND = "create" -o $COMMAND = "restore" -o $COMMAND = "verify" ]; then
    BACKUP_DIR="$1"
    BACKUP_FILE="$2"
    [ -d "$BACKUP_DIR" ] || die "$BACKUP_DIR not found (or not a directory)"
    # Fix BACKUP_FILE if it is not absolute
    if [ ! "$(echo $BACKUP_FILE | cut --characters=1)" = "/" ]; then
        BACKUP_FILE="$(pwd)/$BACKUP_FILE"
    fi
    [ -z "$BACKUP_FILE" ] && die "not enough arguments (BACKUP_FILE = \"$BACKUP_FILE\")"
    BACKUP_FILE_LIST="$BACKUP_FILE.list"
elif [ $COMMAND = list ]; then
    BACKUP_FILE="$1"
    [ $COMPRESS = gpg ] && die "list and -e are incompatible"
else
    die "unknown command: $COMMAND"
fi

if [ $COMMAND != "create" -a ! -f "$BACKUP_FILE" ]; then
    die "$BACKUP_FILE is not a file"
fi

# ================ Setup output ================
OUTPUT_OPTION=">$BACKUP_FILE"
if [ ! -z "$SPLIT_SIZE" ]; then
  which split >/dev/null || die "split program not found"
  OUTPUT_OPTION="| split --numeric-suffixes --suffix-length=$SPLIT_SUFFIX_LENGTH \
                   --bytes=$SPLIT_SIZE - $BACKUP_FILE."
fi

# ================ Create options ================
CREATE_COMMON="cpio -o -H newc -0 --quiet"
LIST_COMMON="cpio -t -H newc --quiet"
INSTALL_COMMON="cpio -i -H newc --quiet"
VERIFY_COMMON="cpio -itv -H newc"

# ================================
case $COMMAND in
  create)
    cd $BACKUP_DIR
    RUNME="$CREATE_COMMON $K_OPTION"
    if [ ! -z "$FILTER_COMMAND" ]; then
        RUNME="$RUNME | $FILTER_COMMAND"
    fi
    RUNME="$RUNME 2>$BACKUP_FILE_LIST $OUTPUT_OPTION"
    echo "command: $FIND_PIPE | $RUNME"
    eval "$FIND_PIPE | $RUNME"
  ;;

  restore)
    cd $BACKUP_DIR
    RUNME="$INSTALL_COMMON"
    if [ ! -z "$FILTER_COMMAND" ]; then
        RUNME="$FILTER_COMMAND | $RUNME"
    fi
    RUNME="$RUNME < $BACKUP_FILE"
    echo "command: $RUNME 2>$STDERR_LOG"
    eval "$RUNME 2>$STDERR_LOG"
  ;;

  verify)
    cd $BACKUP_DIR
    RUNME="$VERIFY_COMMON"
    if [ ! -z "$FILTER_COMMAND" ]; then
        RUNME="$FILTER_COMMAND | $RUNME"
    fi
    RUNME="$RUNME < $BACKUP_FILE"
    echo "command: $RUNME"
    eval "$RUNME"
  ;;

  list)
    RUNME="$LIST_COMMON < $BACKUP_FILE"
    echo "command: $RUNME"
    eval "$RUNME"
  ;;
esac


