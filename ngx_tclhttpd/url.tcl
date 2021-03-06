# url.tcl
#
# This is the URL dispatcher.  The URL hierarchy is divided into "domains"
# that are subtrees of the URL space with a particular type.  A domain is
# identified by the name of its root, which is a prefix of the URLs in
# that domain.  The dispatcher selects a domain by the longest matching
# prefix, and then calls a domain handler to process the URL.  Different
# domain handlers correspond to files (Doc), cgi-bin directories (Cgi),
# and things built right into the application (Direct).
#
# URL processing is divided into two parts: access control and
# url implementation.  You register access hooks with
# Url_AccessInstall, and you register URL implementations with
# Url_PrefixInstall.
#
# Brent Welch (c) 1997 Sun Microsystems, 1998-2000 Scriptics Corporation.
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.
#
# SCCS: @(#) url.tcl 1.7 97/08/20 11:50:13
package provide httpd::url 0.9

# This pattern cannot occur inside a URL path component
# On windows we disallow : to avoid drive-letter attacks

switch $tcl_platform(platform) {
    windows	{ set Url(fsSep) {[/\\:]} }
    macintosh	{ set Url(fsSep) : }
    unix	-
    default	{ set Url(fsSep) / }
}

# Url_Dispatch
#
#	Dispatch to a type-specific handler for a URL
#
# Arguments
#	sock	THe client socket connection
#
# Side Effects
#	Handle the request

proc Url_Dispatch {sock} {
    global Url
    upvar #0 Httpd$sock data

    catch {after cancel $data(cancel)}
    set url $data(url)

    if {[catch {

	# INLINE VERSION OF Url_PrefixMatch

	# Collapse multiple // to avoid tricks like //cgi-bin that fail
	# to match the /cgi-bin prefix
	regsub -all /+ $url / url

	if {![regexp ^($Url(prefixset))(.*) $url x prefix suffix] ||
		([string length $suffix] && ![string match /* $suffix])} {

	    # Fall back and assume it is under the root
	    # The /+ gobbles extra /'s that might be used to sneak
	    # out to the root of the file hierarchy.

	    regexp ^(/+)(.*) $url x prefix suffix
	    set prefix /
	}

	# END INLINE

	# Do access control before dispatch,
	# but after prefix/suffix determination

	set data(prefix) $prefix
	set data(suffix) $suffix

	foreach hook $Url(accessHooks) {
	    switch -- [{*}$hook $sock $url] {
		ok	{ break }
                return  -
		denied	{
		    # A URL implementation should have generated the
		    # appropriate response, such as a 403, to request
		    # a retry. But, if it hasn't, we generate a default.

		    if {![Httpd_RequestComplete $sock]} {
			Httpd_Error $sock 403
		    }
		    return
		}
		skip	{ continue }
	    }
	}

	# Register a callback with the Httpd layer

	if {[info exist Url(callback,$prefix)]} {
	    Httpd_CompletionCallback $sock $Url(callback,$prefix)
	}

	# Pre-read the post data, if the domain wants that

	if {$Url(readpost,$prefix) && $data(count) > 0} {
	    
	    Httpd_ReadPostDataAsync $sock \
		[list Url_DeferredDispatch $prefix $suffix]
	    return
	}

        {*}$Url(command,$prefix) $sock $suffix
    } error] == 1} {

	# Only do this on uncaught errors.
	# Note that the return statement for the "denied" case of the
	# access hook will result in catch returning code == 2, not 1 (or zero)

	global errorInfo
	global errorCode
	Url_Unwind $sock $errorInfo $errorCode
    }
}

# Url_DeferredDispatch
#
#	Dispatch to a type-specific handler for a URL after the
#	post data has been read.
#
# Arguments
#	sock	The client socket connection
#
# Side Effects
#	Handle the request

proc Url_DeferredDispatch {prefix suffix sock varname errmsg} {
    global Url

    if {[string length $errmsg]} {
	Httpd_SockClose $sock 1 $errmsg
	return
    }
    Url_PostHook $sock 0	;# Turn of Url_ReadPost
    if {[catch {
        {*}$Url(command,$prefix) $sock $suffix
    } error] == 1} {
	global errorInfo
	global errorCode
	Url_Unwind $sock $errorInfo $errorCode
    }
}

# Url_PrefixMatch
#	Match the domain prefix of a URL
#
# Arguments
#	url	The input URL
#	suffixVar	Output variable, the suffix
#	prefixVar	Output variable, the prefix
#
# Results
#	Fills in prefix and suffix result variables

proc Url_PrefixMatch {url prefixVar suffixVar} {
    global Url
    upvar 1 $prefixVar prefix
    upvar 1 $suffixVar suffix

    # Prefix match the URL to get a domain handler
    # Fast check on domain prefixes with regexp
    # Check that the suffix starts with /, otherwise the prefix
    # is not a complete component.  E.g., "/tcl" vs "/tclhttpd"
    # where /tcl is a domain prefix but /tclhttpd is a directory
    # in the / domain.

    # IF YOU CHANGE THIS  - FIX in-line CODE IN URL_DISPATCH

    # Collapse multiple // to avoid tricks like //cgi-bin that fail
    # to match the /cgi-bin prefix
    regsub -all /+ $url / url

    if {![info exist Url(prefixset)] ||
	    ![regexp ^($Url(prefixset))(.*) $url x prefix suffix] ||
	    ([string length $suffix] && ![string match /* $suffix])} {
	# Fall back and assume it is under the root
	regexp ^(/+)(.*) $url x prefix suffix
	set prefix /
    }
}

# Url_PrefixExists
#	Determine if a prefix has been registered.
#
# Arguments
#	prefix	The input URL
#
# Results
#	0 or 1

proc Url_PrefixExists {prefix} {
    global Url
    return [info exist Url(command,$prefix)]
}

# Url_Unwind
#	Do common error handling after a URL request
#
# Arguments
#	sock	The client connection
#	ei	The errorInfo from the command
#	ec	The errorCode from the command
#
# Side Effects
#	Clean up the connection and ensure a reply

proc Url_Unwind {sock ei ec} {

    # URL implementations can raise special errors to unwind their processing.

    set key [lindex $ec 0]
    set error [lindex [split $ei \n] 0]
    switch -- $key {
        HTTPD_REDIRECT {

	    # URL implementations can raise an error and put redirect info
	    # into the errorCode variable, which should be of the form
	    # HTTPD_REDIRECT $newurl

            Httpd_Redirect [lindex $ec 1] $sock
            return
        }
        HTTPD_SUSPEND {
	    
	    # The domain handler has until Httpd(timeout2) to complete this request
	    
            Httpd_Suspend $sock
            return
        }
    }

    switch -glob -- $ei {
	"*can not find channel*"  {
	    Httpd_SockClose $sock 1 $error
	}
	default {
            Httpd_Error $sock 500 $ei
	}
    }
}

# Url_AccessInstall
#
#	Install an access check hook.
#
# Arguments
#	proc	This is a command prefix that is invoked with two additional
#		arguments to check permissions:
#			sock	The handle on the connection
#			url	The url being accessed
#		The access hook should return:
#			"ok"	Meaning access is allowed
#			"denied" Access is denied and the hook is responsible
#				for generating the Authenticate challenge
#			"skip"	Meaning the hook doesn't care about the URL,
#				but perhaps another access control hook does.
#
# Side Effects
#	Save the access control hook

proc Url_AccessInstall {proc} {
    global Url
    if {[lsearch $Url(accessHooks) $proc] < 0} {
	lappend Url(accessHooks) $proc
    }
    return
}

# Url_AccessInstallPrepend
#
#       Exactly like AccessInstall, but puts the hook first in the list

proc Url_AccessInstallPrepend {proc} {
    global Url
    if {[lsearch $Url(accessHooks) $proc] < 0} {
	set Url(accessHooks) [concat $proc $Url(accessHooks)]
    }
    return
}

# Url_AccessUnInstall
#
#       Remove an access control hook
#
# Arguments
#	proc	A procedure previously registered with Url_AccessInstall
#
# Side Effects
#	Remove the access control hook

proc Url_AccessUnInstall {proc} {
    global Url
    set ix [lsearch $Url(accessHooks) $proc]
    if {$ix >= 0} {
	set Url(accessHooks) [lreplace $Url(accessHooks) $ix $ix]
    }
    return
}

if {![info exist Url(accessHooks)]} {
    set Url(accessHooks) {}
}

# Url_PrefixInstall
#	Declare that a handler exists for a point in the URL tree
#	identified by the prefix of all URLs below that point.
#
# Arguments:
#	prefix	The leadin part of the URL, (e.., /foo/bar)
#	command	THe Domain handler command.  This is invoked with one
#		additional arument, $sock, that is the handle identifier
#		A well-known state array is available at
#		upvar #0 Httpd$sock 
#	args	This is either a single boolean that, for backwards
#		compatibility, indicates if the domain handler runs
#		in a thread, or an option-value list of:
#		-callback cmd
#			A callback to make when the request completes
#			with or without error, timeout, etc.
#		-readpost boolean
#			To indicate we should pre-read POST data.

proc Url_PrefixInstall {prefix command args} {
    global Url

    # Add the url to the prefixset, which is a regular expression used
    # to pick off the prefix from the URL

    regsub -all {([][\\().*+?$|])} $prefix {\\\1} prefixquoted

    if {[string compare $prefix "/"] == 0} {
	# / is not in the prefixset because of some special cases.
	# See Url_Dispatch
    } elseif {![info exists Url(prefixset)]} {
	set Url(prefixset) $prefixquoted
    } else {
	set list [split $Url(prefixset) |]
	if {[lsearch $list $prefixquoted] < 0} {
	    lappend list $prefixquoted
	}
	set Url(prefixset) [join [lsort -command UrlSort $list] |]
    }

    # Install the unquoted prefix so the Url dispatch works right

    set Url(command,$prefix) $command

    # Most domains have small amounts of POST data so we read it
    # by default for them.  If you post massive amounts, create
    # a special domain that handles the post data specially.

    set readpost 1

    # Check for options on the domain

    foreach {n v} $args {
        switch -- $n {
            -callback {
                set Url(callback,$prefix) $v
            }
            -readpost {
                set readpost $v
            }
            default {
                return -code error "Unknown option $n.\
                    Must be -thread, -callback, or -readpost"
            }
        }
    }
    set Url(readpost,$prefix) $readpost
}

# Url_PrefixRemove
#
#	Undo a prefix registration
#
# Arguments:
#	prefix	The leadin part of the URL, (e.., /foo/bar)
#
# Side Effects:
#	Remove the prefix from the dispatch set.

proc Url_PrefixRemove {prefix} {
    global Url

    # Delete the prefix from the regular expression used to match URLs

    regsub -all {([][\\().*+?$|])} $prefix {\\\1} prefixquoted
    set list [split $Url(prefixset) |]
    ldelete list $prefixquoted
    set Url(prefixset) [join [lsort -command UrlSort $list] |]
    if {[info exist Url(command,$prefix)]} {
	unset Url(command,$prefix)
	unset Url(thread,$prefix)
    }
    if {[info exist Url(callback,$prefix)]} {
	unset Url(callback,$prefix)
    }
}

# UrlSort
#
#	Sort the URL prefixes so the longest ones are first.
#	The makes the regular expression match the longest
#	matching prefix.
#
# Arguments:
#	a, b	To URL prefixes
#
# Results:
#	1 if b should sort before a, -1 if a should sort before b, else 0

proc UrlSort {a b} {
    set la [string length $a]
    set lb [string length $b]
    if {$la == $lb} {
	return [string compare $a $b]
    } elseif {$la < $lb} {
	return 1
    } else {
	return -1
    }
}

# Url_PathCheck
#
#	Validate a pathname.  Make sure it doesn't sneak out of its domain.
#
# Arguments:
#	urlsuffix	The URL after the domain prefix
#
# Results:
#	Raises an error, or returns a list of components in the pathname

proc Url_PathCheck {urlsuffix} {
    global Url
    set pathlist ""
    foreach part  [split $urlsuffix /] {
	if {[string length $part] == 0} {

	    # It is important *not* to "continue" here and skip
	    # an empty component because it could be the last thing,
	    # /a/b/c/
	    # which indicates a directory.  In this case you want
	    # Auth_Check to recurse into the directory in the last step.

	}
	set part [Url_Decode $part]

	# Disallow Mac and UNIX path separators in components
	# Windows drive-letters are bad, too

	if {[regexp $Url(fsSep) $part]} {
	    error "URL components cannot include $Url(fsSep)"
	}
	switch -- $part {
	    .  { }
	    .. {
		set len [llength $pathlist]
		if {[incr len -1] < 0} {
		    error "URL out of range"
		}
		set pathlist [lrange $pathlist 0 [incr len -1]]
	    }
	    default {
		lappend pathlist $part
	    }
	}
    }
    return $pathlist
}

proc Url_PostHook {sock length} {
    global Url

    # Backdoor hack for Url_DecodeQuery compatibility
    # We remember the current connection so that Url_DecodeQuery
    # can read the post data if it has not already been read by
    # the time it is called.

    set Url(sock) $sock
    set Url(postlength) $length
}

# convert a x-www-urlencoded string into a list of name/value pairs

proc Url_DecodeQuery {query args} {
    global Url

    if {[info exist Url(sock)]} {
	Url_ReadPost $Url(sock) query
    }
    Url_DecodeQueryOnly $query {*}$args
}

# Url_QuerySetup --
#
#	Grab any query data and pass it to the ncgi:: module.
#
# Arguments:
# 	sock	The socket back to the client.
#
# Results:
#	None
#
# Side effects:
#	ncgi::reset, ncgi::parse, ncgi::urlstup

proc Url_QuerySetup {sock} {
    upvar #0 Httpd$sock data

    set valuelist {}

    # search for comma separeted pair of numbers
    # as generated from server side map
    #      e.g 190,202
    # Bjorn Ruff.

    if { [regexp {^([0-9]+),([0-9]+)$} $data(query) match x y]} {
	set data(query) x=$x&y=$y
    }

    # Honor content type of the query data
    # Some browsers leave junk Content-Type lines in
    # non-post requests as a side effect of keep alive.

    if {[info exist data(mime,content-type)] &&
	    ("$data(proto)" != "GET")} {
	set type $data(mime,content-type)
    } else {
	set type application/x-www-urlencoded
    }

    # Grab POST data, if any, and initialize the ncgi:: interface

    Url_ReadPost $sock data(query)
    ncgi::reset $data(query) $type
    ncgi::parse
    ncgi::urlStub $data(url)
    return
}

proc Url_ReadPost {sock varname} {
    upvar 1 $varname query
    global Url

    append query ""
    if {[info exist Url(postlength)] && ($Url(postlength) > 0)} {
	
	# For compatibility with older versions of the Httpd module
	# that used to read all the post data for us, we read it now
	# if it hasn't already been read

	set result $Url(postlength)
	if {[string length $query]} {
	    # This merges query data from the GET/POST URL
	    append query &
	}
	while {$Url(postlength) > 0} {
	    set Url(postlength) [Httpd_GetPostData $sock query]
	}
	unset Url(postlength)
	return $result
    } else {
	return 0
    }
}

proc Url_DecodeQueryOnly {query args} {

    array set options {-type application/x-www-urlencoded -qualifiers {}}
    catch {array set options $args}
    if {[string length [info command Url_DecodeQuery_$options(-type)]] == 0} {
	set options(-type) application/x-www-urlencoded
    }
    return [Url_DecodeQuery_$options(-type) $query $options(-qualifiers)]
}

proc Url_DecodeQuery_application/x-www-urlencoded {query qualifiers} {

    # These foreach loops are structured this way to ensure there are matched
    # name/value pairs.  Sometimes query data gets garbled.

    set result {}
    foreach pair [split $query "&"] {
	foreach {name value} [split $pair "="] {
	    lappend result [Url_Decode $name] [Url_Decode $value]
	}
    }
    return $result
}

proc Url_Decode {data} {
    regsub -all {\+} $data " " data
    regsub -all {([][$\\])} $data {\\\1} data
    regsub -all {%([0-9a-fA-F][0-9a-fA-F])} $data  {[format %c 0x\1]} data
    return [subst $data]
}

# Url_IsLinkToSelf
#	Compare the link to the URL of the current page.
#	If they seem to be the same thing, return 1
#
# Arguments:
#	url	The URL to compare with.
#
# Results:
#	1 if the input URL seems to be equivalent to the page's URL.
#
# Side Effects:
#	None

proc Url_IsLinkToSelf {url} {
    global page
    return [expr {[string compare $url $page(url)] == 0}]
}

