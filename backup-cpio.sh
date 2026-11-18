#!/bin/sh
#
# backup-cpio - backup directories to files using cpio.
# Derived from backup-afio.
#
# backup-cpio version 1.1 - 2026-11-18, ChatGPT modifications.
# -Implement -y/-Y/-w/-W pathname filtering and pattern files.
# -Preserve relative directory structure and NUL-safe filenames.
# -Improve argument quoting, command execution, and error handling.
#
#################################################################################
#
# backup-cpio version 1.0 - converted to use cpio instead of afio.
# Distributed under the terms of the GNU GPL license, available at
# http://www.gnu.org/licenses/gpl.html
#
# Link to version 0.93 https://github.com/tonoono/backup-afio
#
# Link to version 0.92 http://danielwebb.us/software/backup/backup-afio#
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
#
THIS=backup-cpio
PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin
export PATH
SPLIT_SUFFIX_LENGTH=3

fail() { printf '%s: %s\n' "$THIS" "$*" >&2; exit 1; }

short_help() {
    cat <<EOF
$THIS - backup directories to files using cpio

Usage:
  $THIS create [options] <backup directory> <archive file>
  $THIS restore [options] <restore directory> <archive file>
  $THIS verify [options] <backup directory> <archive file>
  $THIS list [options] <archive file>

Options:
  -h           Show full help
  -e           Encrypt/decrypt using GPG
  -r <name>    Set GPG recipient for encryption
  -z           Compress/decompress with gzip
  -b           Compress/decompress with bzip2
  -k           Pass -k to cpio when creating an archive
  -x           Cross filesystem boundaries when finding files
  -s <size>    Split output archive into numbered parts (create only)
  -l <cmd>     Custom NUL-delimited filename generator (trusted shell code)
  -y <pattern> Include matching filenames (create only; repeatable)
  -Y <pattern> Exclude matching filenames (create only; repeatable)
  -w <file>    Read include patterns, one per line (create only)
  -W <file>    Read exclude patterns, one per line (create only)
EOF
}

long_help() {
    short_help
    cat <<'EOF'

Patterns are relative to the backup directory, not the calling directory.
For example, 'cache/' matches only the top-level cache directory and all
its contents. Use 'documents/cache/' for another directory with that name.
A leading './' is optional. '*' matches within one path component; '?' and
[abc] character classes are supported. Use '*/cache/' to match a cache
folder exactly one level below the root. A trailing '/' means a directory
and everything beneath it. Multiple include patterns are ORed; multiple
exclude patterns are ORed. Excludes always win. With no include patterns,
all discovered files are included. Required parent directory entries are
added automatically; the backup root itself is not stored.

Pattern files have one pattern per line. Blank lines and lines beginning
with '#' are ignored. Patterns are interpreted literally as patterns,
never as shell commands. Perl is needed only when a filter option is used.

The -l option executes its argument as shell code. Use only trusted input.
Its command must write NUL-separated filenames relative to the backup root.
The default generator is 'find . -xdev -print0' (or without -xdev for -x).

Only one of -e, -z and -b can be selected. Split archives are created as
<archive>.000, <archive>.001, etc. To restore, join the parts first.

Examples:
  backup-cpio create /home/me /tmp/backup.cpio
  backup-cpio create -Y 'cache/' -Y 'tmp/' /home/me /tmp/backup.cpio
  backup-cpio create -W excludes.txt /home/me /tmp/backup.cpio
  backup-cpio create -y 'documents/*.pdf' /home/me /tmp/docs.cpio
  backup-cpio create -z -s 600m /home/me /tmp/backup.cpio.gz
  backup-cpio restore -z /tmp/restore /tmp/backup.cpio.gz
EOF
}

[ "$#" -gt 0 ] || { short_help; exit 1; }
case "$1" in -h|--help) long_help; exit 0;; esac
COMMAND=$1
shift
case "$COMMAND" in create|restore|verify|list) ;; *) fail "unknown command: $COMMAND";; esac

# Use a private directory, including for pipeline exit statuses.
umask 077
TMP_WORK=$(mktemp -d "${TMPDIR:-/tmp}/backup-cpio.XXXXXXXX") || fail 'cannot create temporary directory'
trap 'rm -rf -- "$TMP_WORK"' 0
trap 'exit 1' 1 2 3 15
INC=$TMP_WORK/include
EXC=$TMP_WORK/exclude
: > "$INC" || fail 'cannot initialize include patterns'
: > "$EXC" || fail 'cannot initialize exclude patterns'

COMPRESS=none
GPG_RECIPIENT=
CROSS=false
K_OPTION=false
SPLIT_SIZE=
FIND_PIPE=
FILTER=false

add_pattern_file() {
    [ -f "$1" ] && [ -r "$1" ] || fail "cannot read pattern file: $1"
    while IFS= read -r entry || [ -n "$entry" ]; do
        case "$entry" in ''|'#'*) continue;; esac
        printf '%s\n' "$entry" >> "$2" || fail "cannot read patterns from $1"
    done < "$1"
}

while getopts ':her:zbkxl:s:w:W:y:Y:' opt; do
    case "$opt" in
        h) long_help; exit 0;;
        e) [ "$COMPRESS" = none ] || fail 'choose only one of -e, -z, -b'; COMPRESS=gpg;;
        z) [ "$COMPRESS" = none ] || fail 'choose only one of -e, -z, -b'; COMPRESS=gzip;;
        b) [ "$COMPRESS" = none ] || fail 'choose only one of -e, -z, -b'; COMPRESS=bzip2;;
        r) GPG_RECIPIENT=$OPTARG;;
        k) K_OPTION=true;;
        x) CROSS=true;;
        l) FIND_PIPE=$OPTARG;;
        s) SPLIT_SIZE=$OPTARG;;
        y) FILTER=true; printf '%s\n' "$OPTARG" >> "$INC";;
        Y) FILTER=true; printf '%s\n' "$OPTARG" >> "$EXC";;
        w) FILTER=true; add_pattern_file "$OPTARG" "$INC";;
        W) FILTER=true; add_pattern_file "$OPTARG" "$EXC";;
        :) fail "option -$OPTARG needs an argument";;
        \?) fail "unknown option: -$OPTARG";;
    esac
done
shift "$((OPTIND - 1))"

if [ "$COMMAND" != create ]; then
    [ "$FILTER" = false ] && [ -z "$FIND_PIPE" ] && [ "$CROSS" = false ] && [ "$K_OPTION" = false ] && [ -z "$SPLIT_SIZE" ] || fail '-y/-Y/-w/-W/-l/-x/-k/-s are create-only'
fi
[ "$FILTER" = false ] || command -v perl >/dev/null 2>&1 || fail 'Perl is required for -y/-Y/-w/-W'
[ "$COMPRESS" != gpg ] || command -v gpg >/dev/null 2>&1 || fail 'gpg not found'
if [ "$COMMAND" = create ] && [ "$COMPRESS" = gpg ]; then
    [ -n "$GPG_RECIPIENT" ] || fail 'GPG recipient required with -e (use -r)'
fi
[ -z "$SPLIT_SIZE" ] || command -v split >/dev/null 2>&1 || fail 'split not found'

case "$COMMAND" in
    create|restore|verify)
        [ "$#" -eq 2 ] || fail 'expected backup/restore directory and archive file'
        BACKUP_DIR=$1
        [ -d "$BACKUP_DIR" ] || fail "not a directory: $BACKUP_DIR"
        BACKUP_FILE=$2
        case "$BACKUP_FILE" in /*) ;; *) BACKUP_FILE=$(pwd)/$BACKUP_FILE;; esac
        ;;
    list)
        [ "$#" -eq 1 ] || fail 'expected one archive file'
        BACKUP_FILE=$1
        ;;
esac
if [ "$COMMAND" != create ]; then
    [ -f "$BACKUP_FILE" ] && [ -r "$BACKUP_FILE" ] || fail "archive not readable: $BACKUP_FILE"
fi

# Every pipeline stage records its own status; POSIX sh has no pipefail.
record_status() {
    stage=$1
    shift
    "$@"
    result=$?
    printf '%s\n' "$result" > "$TMP_WORK/$stage.status"
    return "$result"
}

file_generator() {
    cd -- "$BACKUP_DIR" || return 1
    if [ -n "$FIND_PIPE" ]; then
        # Explicit compatibility escape hatch: user-supplied shell program.
        sh -c "$FIND_PIPE"
    elif [ "$CROSS" = true ]; then
        find . -print0
    else
        find . -xdev -print0
    fi
}

filter_names() {
    if [ "$FILTER" = false ]; then
        cat
        return
    fi
    LC_ALL=C perl -e '
        use strict;
        use warnings;
        binmode STDIN;
        binmode STDOUT;
        my ($incfile, $excfile) = @ARGV;
        sub patterns {
            my ($file) = @_;
            open my $fh, "<", $file or die "cannot open patterns: $!";
            my @result;
            while (my $p = <$fh>) {
                chomp $p;
                $p =~ s{^\./}{};
                next if $p eq "";
                my $dir = ($p =~ s{/$}{});
                my $regex = "";
                while (length $p) {
                    if ($p =~ s/^\*//) { $regex .= "[^/]*"; }
                    elsif ($p =~ s/^\?//) { $regex .= "[^/]"; }
                    elsif ($p =~ s/^\[([^\]\\]+)\]//) {
                        my $cls = $1;
                        if ($cls =~ /^!?[a-zA-Z0-9_\\-]+$/) {
                            $cls =~ s/^!/\^/;
                            $regex .= "[$cls]";
                        } else { $regex .= quotemeta("[$cls]"); }
                    } else {
                        $p =~ s/^(.)//s;
                        $regex .= quotemeta($1);
                    }
                }
                push @result, [$dir ? qr/^$regex(?:\/|$)/ : qr/^$regex$/, $dir];
            }
            close $fh or die "cannot close patterns: $!";
            return @result;
        }
        my @include = patterns($incfile);
        my @exclude = patterns($excfile);
        sub matches {
            my ($name, $rules) = @_;
            for my $rule (@$rules) { return 1 if $name =~ $rule->[0]; }
            return 0;
        }
        my %seen;
        sub emit {
            my ($name) = @_;
            return if $seen{$name}++;
            print STDOUT "./$name\0" or die "output error: $!";
        }
        local $/ = "\0";
        while (defined(my $raw = <STDIN>)) {
            $raw =~ s/\0$//;
            $raw =~ s{^\./}{};
            $raw =~ s{/$}{};
            next if $raw eq "." || $raw eq "";
            die "unsafe filename from generator\n" if $raw =~ m{^/|(?:^|/)\.\.(?:/|$)};
            next if matches($raw, \@exclude);
            next if @include && !matches($raw, \@include);
            my @parts = split m{/}, $raw;
            my $path = "";
            for (my $i = 0; $i < $#parts; $i++) {
                $path .= "/" if length $path;
                $path .= $parts[$i];
                # An excluded ancestor must never be reintroduced.
                next if matches($path, \@exclude);
                emit($path);
            }
            emit($raw);
        }
    ' "$INC" "$EXC"
}

archive_create() {
    cd -- "$BACKUP_DIR" || return 1
    if [ "$K_OPTION" = true ]; then
        cpio -o -H newc -0 --quiet -k 2> "$BACKUP_FILE.list"
    else
        cpio -o -H newc -0 --quiet 2> "$BACKUP_FILE.list"
    fi
}

encode() {
    case "$COMPRESS" in
        none) cat;;
        gzip) gzip;;
        bzip2) bzip2;;
        gpg) gpg --batch --quiet --encrypt --recipient "$GPG_RECIPIENT";;
    esac
}

decode() {
    case "$COMPRESS" in
        none) cat;;
        gzip) gzip -dc;;
        bzip2) bzip2 -dc;;
        gpg) gpg --batch --quiet --decrypt;;
    esac
}

save_archive() {
    if [ -n "$SPLIT_SIZE" ]; then
        split --numeric-suffixes --suffix-length="$SPLIT_SUFFIX_LENGTH" --bytes="$SPLIT_SIZE" - "$BACKUP_FILE."
    else
        cat > "$BACKUP_FILE"
    fi
}

check_stages() {
    failed=false
    for stage in "$@"; do
        if [ ! -f "$TMP_WORK/$stage.status" ]; then
            printf '%s: stage did not complete: %s\n' "$THIS" "$stage" >&2
            failed=true
        else
            status=$(cat "$TMP_WORK/$stage.status")
            if [ "$status" -ne 0 ]; then
                printf '%s: %s failed (status %s)\n' "$THIS" "$stage" "$status" >&2
                failed=true
            fi
        fi
    done
    [ "$failed" = false ] || exit 1
}

case "$COMMAND" in
    create)
        ( record_status find file_generator ) |
        ( record_status filter filter_names ) |
        ( record_status cpio archive_create ) |
        ( record_status compression encode ) |
        ( record_status output save_archive )
        check_stages find filter cpio compression output
        ;;
    restore)
        ( record_status decode decode < "$BACKUP_FILE" ) |
        ( cd -- "$BACKUP_DIR" || exit 1
          record_status extract cpio -i -H newc --quiet 2> "$TMP_WORK/restore.stderr" )
        if [ -s "$TMP_WORK/restore.stderr" ]; then cat "$TMP_WORK/restore.stderr" >&2; fi
        check_stages decode extract
        ;;
    verify)
        # Preserve the original verify behavior: list archive contents verbosely.
        ( record_status decode decode < "$BACKUP_FILE" ) |
        ( cd -- "$BACKUP_DIR" || exit 1
          record_status verify cpio -itv -H newc )
        check_stages decode verify
        ;;
    list)
        ( record_status decode decode < "$BACKUP_FILE" ) |
        ( record_status list cpio -t -H newc --quiet )
        check_stages decode list
        ;;
esac
