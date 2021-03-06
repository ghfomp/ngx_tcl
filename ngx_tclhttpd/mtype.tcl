# mimetype.tcl --
# Code to deal with mime types
#
# Brent Welch (c) 1997 Sun Microsystems
# Brent Welch (c) 1998-2000 Ajuba Solutions
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.
#
# RCS: @(#) $Id: mtype.tcl 5904 2010-10-18 07:28:06Z dino $

package provide httpd::mtype 0.9

# Convert the file suffix into a mime type

# global MimeType is a mapping from file extension to mime-type

proc Mtype {path} {
    global MimeType

    set ext [string tolower [file extension $path]]
    if {[info exist MimeType($ext)]} {
	return $MimeType($ext)
    } else {
	return text/plain
    }
}

# Read a mime types file into the mimeType array.
# Set up some minimal defaults if no file is available.

proc Mtype_ReadTypes {file} {
    global MimeType

    array set MimeType {
	{}	text/plain
	.txt	text/plain
	.htm	text/html
	.html	text/html
	.tml	application/x-tcl-template
	.gif	image/gif
	.thtml	application/x-safetcl
	.shtml	application/x-server-include
	.cgi	application/x-cgi
	.map	application/x-imagemap
	.subst	application/x-tcl-subst
    }

    set in [open $file]

    while {[gets $in line] >= 0} {
	if {[regexp {^( 	)*$} $line]} {
	    continue
	}
	if {[regexp {^( 	)*#} $line]} {
	    continue
	}
	if {[regexp {([^ 	]+)[ 	]+(.+)$} $line match type rest]} {
	    foreach item [split $rest] {
		if {[string length $item]} {
		    set MimeType([string tolower .$item]) $type
		}
	    }
	}
    }
    close $in
}

# Mtype_Accept --
#
#	This returns the Accept specification from the HTTP headers.
#	These are a list of MIME types that the browser favors.
#
# Arguments:
#	sock	The socket connection
#
# Results:
#	The Accept header, or a default.
#
# Side Effects:
#	None

proc Mtype_Accept {sock} {
    upvar #0 Httpd$sock data
    if {![info exist data(mime,accept)]} {
	return */*
    } else {
	return $data(mime,accept)
    }
}
