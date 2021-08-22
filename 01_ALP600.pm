########################################################################################
#
# ALP600.pm
#
# FHEM module for ALpha Go ALP-600
#
# Christian Hoenig
#
# $Id$
#
########################################################################################
#
#  This programm is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
########################################################################################
package main;

use strict;
use warnings;
use JSON;

use Data::Dumper;

my $version = "0.10.0";

my $ALP600_hasMimeBase64 = 1;
my $ALP600_hasNetPing    = 1;
my $ALP600_hasXmlSimple  = 1;

#------------------------------------------------------------------------------------------------------
# Initialize
#------------------------------------------------------------------------------------------------------
sub ALP600_Initialize($)
{
	my ($hash) = @_;

	eval "use MIME::Base64";
	$ALP600_hasMimeBase64 = 0 if($@);

	eval "use Net::Ping";
	$ALP600_hasNetPing = 0 if($@);

	eval "use XML::Simple";
	$ALP600_hasXmlSimple = 0 if($@);

	$hash->{DefFn}     = "ALP600_DefFn";
	$hash->{UndefFn}   = "ALP600_UndefFn";
	$hash->{DeleteFn}  = "ALP600_DeleteFn";
	$hash->{AttrFn}    = "ALP600_AttrFn";
	$hash->{SetFn}     = "ALP600_SetFn";
	# $hash->{GetFn}     = "ALP600_GetFn";
	$hash->{RenameFn}  = "ALP600_RenameFn";
	$hash->{NotifyFn}  = "ALP600_NotifyFn";

	my $webhookFWinstance   = join( ",", devspec2array('TYPE=FHEMWEB:FILTER=TEMPORARY!=1') );
	$hash->{AttrList}      .= "disable:1 ";
	$hash->{AttrList}      .= "idleDoorContact ";
	$hash->{AttrList}      .= "idleOnOutput:multiple-strict,1,2,3 ";
	$hash->{AttrList}      .= "idleTimeout:0,5,10,20,30,60,120 ";
	$hash->{AttrList}      .= "notifyOfficialApp:both,ring,motion,none ";
	$hash->{AttrList}      .= "outputCheckInterval:0,1,2,3,5,10 ";
	$hash->{AttrList}      .= "pingInterval:0,1,5,10,20,30,60,600,3600 " if ($ALP600_hasNetPing);
	$hash->{AttrList}      .= "username ";
	$hash->{AttrList}      .= "webhookFWinstance:$webhookFWinstance ";
	$hash->{AttrList}      .= "webhookHttpHostname ";
	$hash->{AttrList}      .= $readingFnAttributes;

	# update version in devices
	foreach my $d (sort keys %{$modules{ALP600}{defptr}}) {
		my $hash = $modules{ALP600}{defptr}{$d};
		$hash->{VERSION} = $version;
	}
}

#------------------------------------------------------------------------------------------------------
# Define
#------------------------------------------------------------------------------------------------------
sub ALP600_DefFn($$)
{
	my ( $hash, $def ) = @_;

	# eval { require XML::Simple; };
	# return "Please install Perl XML::Simple to use module ALP600" if ($@);

	# eval { require Net::Ping; };
	# return "Please install Perl Net::Ping to use module ALP600" if ($@);

	my @a = split( "[ \t]+", $def );
	splice( @a, 1, 1 );

	# check syntax
	if(int(@a) != 2) {
		return "Wrong syntax: use define <name> ALP600 <IP>";
	}

	my ($name, $ip) = @a;

	$hash->{IP}               = $ip;
	$hash->{VERSION}          = $version;
	$hash->{WEBHOOK_REGISTER} = "unknown";
	$hash->{STATE}            = 'Initializing';

	$hash->{HAS_MimeBase64} = $ALP600_hasMimeBase64;
	$hash->{HAS_NetPing   } = $ALP600_hasNetPing;
	$hash->{HAS_XmlSimple } = $ALP600_hasXmlSimple;

	$attr{$name}{icon} = "ring" if(!defined($attr{$name}{icon}));
	#$attr{$name}{room} = "ALP600" if( !defined( $attr{$name}{room} ) );

	if ($init_done) {
		InternalTimer( gettimeofday()+0, "ALP600_finishSetup", $hash);
	} else {
		InternalTimer( gettimeofday()+10, "ALP600_finishSetup", $hash);
	}

	return undef;
}

#------------------------------------------------------------------------------------------------------
# finish setup of ALP600 device
#------------------------------------------------------------------------------------------------------
sub ALP600_finishSetup($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	ALP600_Log($hash, 5, "called");

	# try to get the SERIAL
	if (!$hash->{SERIAL})
	{
		# parse serial from mac
		my $serial = ALP600_blockingGetSerial($hash);
		if (!$serial) {
			$hash->{STATE} = 'Error';
			readingsSingleUpdate($hash, "lastError", "Could not get Serial from $name", 1);
			return undef;
		}
		$hash->{SERIAL} = $serial;

		# check if $serial exists already
		my $d = $modules{ALP600}{defptr}{$serial};
		if (defined($d) && $d->{NAME} ne $name) {
			$hash->{STATE} = 'Error';
			readingsSingleUpdate($hash, "state", "ALP600 device with Serial $serial already defined as $d->{NAME}.", 1);
			readingsSingleUpdate($hash, "lastError", "ALP600 device with Serial $serial already defined as $d->{NAME}.", 1);
			$hash->{DUPLICATE_INSTANCE} = "1";
			return undef;
		}
	}

	my $serial = $hash->{SERIAL};

	# remember us
	$modules{ALP600}{defptr}{$serial} = $hash;
	$hash->{STATE} = 'Initialized';
	fhem("deletereading $name lastError");

	ALP600_Log($hash, 3, "finished define with Serial: $serial");

	my $infix = "ALP600";
	ALP600_addExtension( $hash, "ALP600_CGI", $infix );

	if ($init_done) {
		InternalTimer( gettimeofday()+0, "ALP600_updateCallbackStatus", $hash, 0 );
		InternalTimer( gettimeofday()+0, "ALP600_requestSysteminfo", $hash, 0 );
	} else {
		InternalTimer( gettimeofday()+10, "ALP600_updateCallbackStatus", $hash, 0 );
		InternalTimer( gettimeofday()+10, "ALP600_requestSysteminfo", $hash, 0 );
	}

	ALP600_pingDevice($hash) if ($ALP600_hasNetPing);
	ALP600_checkOutput($hash);

	return undef;
}

#------------------------------------------------------------------------------------------------------
# Undefine
#------------------------------------------------------------------------------------------------------
sub ALP600_UndefFn($$)
{
	my ($hash, $name) = @_;

	ALP600_removeExtension($hash);

	RemoveInternalTimer($hash);

	my $serial = $hash->{SERIAL};
	ALP600_Log($hash, 3, "undefined with Code: $serial");
	delete($modules{ALP600}{defptr}{$serial});

	ALP600_Log($hash, 4, "undefined");
	return undef;
}

#------------------------------------------------------------------------------------------------------
# Delete
#------------------------------------------------------------------------------------------------------
sub ALP600_DeleteFn($$)
{
	my ($hash, $name) = @_;

	ALP600_deleteBasicAuth($hash);

	ALP600_Log($hash, 4, "deleted");
	return undef;
}

#------------------------------------------------------------------------------------------------------
# Rename
#------------------------------------------------------------------------------------------------------
sub ALP600_RenameFn($$)
{
	my ($newName, $oldName) = @_;

	return unless (defined($defs{$newName}));
	my $newHash = $defs{$newName};

	ALP600_renameBasicAuth($newHash, $oldName, $newName);
}

#------------------------------------------------------------------------------------------------------
# FWEXT -> ALP600_CGI
#------------------------------------------------------------------------------------------------------
sub ALP600_CGI()
{
	my ($request) = @_;

  	#my $header = join("\n", @FW_httpheader);
  	#ALP600_Log($hash, 3, "===================================================");
  	#ALP600_Log($hash, 3, "received: $header");
  	#ALP600_Log($hash, 3, "received: $request");

	my ($empty, $base, $query) = split(/[\/\?]/, $request, 3);
	ALP600_Log(undef, 5, "received: $base, $query");

	my $webArgs = ALP600_splitIntoHash($query, "&");

	# extract serial
	my $serial = $webArgs->{serial};
	if (!$serial) {
		ALP600_Log(undef, 3, "'serial' is missing");
		return (undef, undef);
	}

	# extract event
	my $event = exists($webArgs->{event}) ? $webArgs->{event}
	                                      : exists($webArgs->{ring})   ? "ring"
	                                      : exists($webArgs->{motion}) ? "motion" : "";
	if (!$event) {
		ALP600_Log(undef, 3, "'event' is missing");

		# we cannot continue without event, but this might be a "Test" call, so return something valid
		return ("text/html; charset=UTF-8", "");
	}

	if (ALP600_handleCGI($serial, $event)) {
		return ("text/html; charset=UTF-8", "");
	} else {
		return (undef, undef);
	}
}

#------------------------------------------------------------------------------------------------------
# ALP600_CGI -> ALP600_handleCGI (this is also used to simulate motion/ring)
#------------------------------------------------------------------------------------------------------
sub ALP600_handleCGI($$)
{
	my ($serial, $event) = @_;
	my $name = "-";

	# find $hash for $serial
	my $found = 0;
	my $hash;
	if (defined($modules{ALP600}{defptr})) {
		# using another iterating syntax made every second request fail ?!?
		for my $key (keys %{ $modules{ALP600}{defptr} })
		{
			$hash = $modules{ALP600}{defptr}{$key};
			$name = $hash->{NAME};
			my $devSerial = InternalVal($name, "SERIAL", undef);
			next if (!$devSerial || $devSerial ne $serial);

			$found = 1;
			last;
		}
	}

	if (!$found) {
		ALP600_Log(undef, 3, "ERROR: No ALP600 device found for Serial $serial");
		return 0;
	}

	# return something valid as there is no error
	return 1 if (ALP600_isDisabled($hash));

	$hash->{WEBHOOK_COUNTER}++;
	$hash->{WEBHOOK_LAST} = TimeNow();

	ALP600_Log($hash, 5, "Received '$event' webhook for ALP600 $serial at device $name");

	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "state", $event);
	readingsBulkUpdate($hash, "event", $event);
	if ($event eq "ring" || $event eq "motion") {
		readingsBulkUpdate($hash, $event, TimeNow());
	}

	readingsEndUpdate($hash, 1 );

	# trigger resetToIdle-timer
	my $timeout = AttrVal($name, "idleTimeout", "30");
	if ($timeout > 0) {
		RemoveInternalTimer($hash, "ALP600_resetToIdle");
		InternalTimer(gettimeofday()+$timeout, "ALP600_resetToIdle", $hash);
	}

	my $notifyOfficialApp = AttrVal($name, "notifyOfficialApp", "none");
	if ($notifyOfficialApp ne "none") {
		InternalTimer(gettimeofday()+0, "ALP600_notifyOfficialApp", $hash);
	}

	return 1;
}

#------------------------------------------------------------------------------------------------------
# AttrFn
#------------------------------------------------------------------------------------------------------
sub ALP600_AttrFn(@)
{
	my ($cmd, $name, $attrName, $attrVal) = @_;
	my $hash = $defs{$name};

	######################
	#### disable #########

	if ($attrName eq "disable") {
		if ($cmd eq "set" && $attrVal eq "1") {
			readingsSingleUpdate ( $hash, "state", "disabled", 1 );
			ALP600_Log($hash, 3, "disabled");
		}

		elsif ($cmd eq "del") {
			readingsSingleUpdate ( $hash, "state", "active", 1 );
			ALP600_Log($hash, 3, "enabled");
		}
	}

	########################
	#### pingInterval ######

	if ($attrName eq "pingInterval") {
		if ($ALP600_hasNetPing) {
			InternalTimer(gettimeofday()+0, "ALP600_pingDevice", $hash, 0);
		} else {
			return "Please install Net::Ping to use the pingInterval";
		}
	}

	###############################
	#### outputCheckInterval ######

	if ($attrName eq "outputCheckInterval") {
		InternalTimer(gettimeofday()+0, "ALP600_checkOutput", $hash, 0);
	}

	#######################
	#### idleDoorContact ######

	if ($attrName eq "idleDoorContact") {
		if ($cmd eq "set") {
			my ($dev, $eventRegExp) = split(":", $attrVal, 2);
			if (length($dev) == 0 || length($eventRegExp) == 0) {
				return "idleDoorContact must have the form device:eventRegExp";
			}
			# workaround as notifyRegexpChanged() does not do what I want :(
			$hash->{NOTIFYDEV}    = $dev;
			$hash->{NOTIFYREGEXP} = $eventRegExp;
			%ntfyHash = (); # enforce recreation of hash
		} else {
			delete ($hash->{NOTIFYDEV});
			delete ($hash->{NOTIFYREGEXP});
			%ntfyHash = (); # enforce recreation of hash
		}
	}

	####################
	#### username ######

	if ($attrName eq "username") {
		if ($cmd eq "set") {
			return "Invalid value for attribute $attrName" if (!$attrVal);
			if ($init_done) {
				InternalTimer(gettimeofday()+0, "ALP600_finishSetup", $hash, 0);
			}
		}
	}

	######################
	#### webhook #########

	if ($attrName eq "webhookHttpHostname") {
		return "Invalid value for attribute $attrName: can only by FQDN or IPv4 or IPv6 address"
		    if ($attrVal && $attrVal !~ /^([A-Za-z_.0-9]+\.[A-Za-z_.0-9]+)|[0-9:]+$/);
	}

	if ($attrName eq "webhookFWinstance") {
		return "Invalid value for attribute $attrName: FHEMWEB instance $attrVal not existing"
		    if ($attrVal && ( !defined( $defs{$attrVal} ) || $defs{$attrVal}{TYPE} ne "FHEMWEB" ));

		$hash->{WEBHOOK_PORT} = InternalVal($attrVal, "PORT", "");
		$hash->{WEBHOOK_URI}  = "/" . AttrVal($attrVal, "webname", "fhem") . "/ALP600";
	}

	return undef;
}

#------------------------------------------------------------------------------------------------------
# SetFn
#------------------------------------------------------------------------------------------------------
sub ALP600_SetFn($$@)
{
	my ($hash, $name, @aa) = @_;
	my ($cmd, @args) = @aa;

	# password is allowed even when 'disabled'
	my $list = "password ";

	if ($cmd eq "?") {
		return "Unknown argument $cmd, choose one of $list" if ALP600_isDisabled($hash);
	}

	if( $cmd eq 'activateOutput' ) {
		return "usage: activateOutput [1|2|3]" if( @args != 1 || $args[0] !~ /^1|2|3$/ );
		ALP600_activateOutput($hash, int($args[0]));
		return undef;
	}
	elsif( $cmd eq 'callback' ) {
		return "usage: callback [both|ring|motion|none]" if(@args != 1);
		ALP600_setCallbackInDevice($hash, $args[0]);
		return undef;
	}
	elsif( $cmd eq 'createIPCAMdevice' ) {
		return "usage: createIPCAMdevice <name>" if(@args != 1);
		ALP600_createIPCAMdevice($hash, $args[0]);
		return undef;
	}
	elsif( $cmd eq 'password' ) {
		return "usage: password <password>" if(@args != 1);
		my $err = ALP600_setBasicAuth($hash, $args[0]);
		return "could not store password: $err" if($err);
		if ($init_done) {
			InternalTimer(gettimeofday()+0, "ALP600_finishSetup", $hash, 0);
		}
		return undef;
	}
	elsif( $cmd eq 'requestSystemInfo' ) {
		return "usage: requestSystemInfo" if( @args != 0 );
		ALP600_requestSysteminfo($hash);
		return undef;
	}
	elsif( $cmd eq 'requestSysParam' ) {
		return "usage: requestSysParam" if( @args != 0 );
		ALP600_requestSysparam($hash);
		return undef;
	}
	elsif( $cmd eq 'requestCallbacks' ) {
		return "usage: requestCallbacks" if( @args != 0 );
		my %tmp = ALP600_requestCallbacks($hash);
		return Dumper(\%tmp);
	}
	elsif( $cmd eq 'simulate' ) {
		return "usage: simulate" if( @args != 1 );
		ALP600_handleCGI($hash->{SERIAL}, $args[0]);
		return undef;
	}
	else
	{
		# these are only allowed when ALP is not 'disabled'
		$list   .= "activateOutput:1,2,3 ";
		$list   .= "callback:both,ring,motion,none ";
		$list   .= "createIPCAMdevice ";
		$list   .= "requestSystemInfo:noArg ";
		$list   .= "requestSysParam:noArg " if ($ALP600_hasXmlSimple);
		$list   .= "requestCallbacks:noArg ";
		$list   .= "simulate:motion,ring " if (ALP600_isDevelopment());
		return "Unknown argument $cmd, choose one of $list";
	}
}

#------------------------------------------------------------------------------------------------------
# Notify
#------------------------------------------------------------------------------------------------------
sub ALP600_NotifyFn($$)
{
	my ($hash, $devHash) = @_;
	my $name = $hash->{NAME};

	return if (ALP600_isDisabled($hash));
	return if (!defined($hash->{NOTIFYDEV})    || $hash->{NOTIFYDEV} eq "");
	return if (!defined($hash->{NOTIFYREGEXP}) || $hash->{NOTIFYREGEXP} eq "");

	my $events = deviceEvents($devHash, 1);
	return if (!$events);

	foreach my $event (@{$events}) {
		next unless (defined($event));

		if ($event =~ $hash->{NOTIFYREGEXP}) {
			ALP600_resetToIdle($hash);
			return;
		}
	}
}

#------------------------------------------------------------------------------------------------------
# ping the device
#------------------------------------------------------------------------------------------------------
sub ALP600_pingDevice($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	return unless ($ALP600_hasNetPing);

	RemoveInternalTimer($hash, "ALP600_pingDevice");

	my $pingInterval = int(AttrVal($name, "pingInterval", "0"));
	if ($pingInterval > 0)
	{
		if (!ALP600_isDisabled($hash))
		{
			my $ip = $hash->{IP};

			my $p = Net::Ping->new();
			my $reachable = $p->ping($ip, 1);
			$p->close();

			readingsBeginUpdate($hash);
			if ($reachable) {
				readingsBulkUpdate($hash, "ping", "ok", 1);
				readingsBulkUpdate($hash, "state", "ok", 1) if (ReadingsVal($name, "state", "") eq "unreachable");
			} else {
				readingsBulkUpdate($hash, "ping", "unreachable");
				readingsBulkUpdate($hash, "state", "unreachable", 1);
			}
			readingsEndUpdate($hash, 1);
		}

		InternalTimer(gettimeofday() + $pingInterval, "ALP600_pingDevice", $hash);
	} else {
		readingsSingleUpdate($hash, "ping", "disabled", 1);
	}
}

#------------------------------------------------------------------------------------------------------
# check outputs (relais) of the device
#------------------------------------------------------------------------------------------------------
sub ALP600_checkOutput($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	RemoveInternalTimer($hash, "ALP600_checkOutput");

	my $outputCheckInterval = int(AttrVal($name, "outputCheckInterval", "0"));
	if ($outputCheckInterval > 0)
	{
		if (!ALP600_isDisabled($hash)) {
			ALP600_requestControllerStatus($hash);
		}

		InternalTimer(gettimeofday() + $outputCheckInterval, "ALP600_checkOutput", $hash);
	}
}

#------------------------------------------------------------------------------------------------------
# activates the 'alarm' output (i.e. the relais on the base station)
#------------------------------------------------------------------------------------------------------
sub ALP600_activateOutput($$)
{
	my ($hash, $output) = @_;
	my $name = $hash->{NAME};

	return unless ($output == 1 || $output == 2 || $output == 3);

	$output = $output - 1;

	my ($username, $password) = ALP600_getBasicAuth($hash);
	my $alarmoutUrl = "http://" . $hash->{IP} . "/cgi-bin/alarmout_cgi?action=set&Status=1&Output=$output";

	HttpUtils_NonblockingGet({
		url         => $alarmoutUrl,
		timeout     => 5,
		hash        => $hash,
		method      => "GET",
		user        => $username,
		pwd         => $password,
		callback    => sub($$$){}
	});
}

#------------------------------------------------------------------------------------------------------
# Write the Callback to the ALP-600 Device
#------------------------------------------------------------------------------------------------------
sub ALP600_setCallbackInDevice($$)
{
	my ($hash, $type) = @_;
	my $name = $hash->{NAME};

	my $webhookHttpHostname = AttrVal($name, "webhookHttpHostname", "");
	my $webhookFWinstance   = AttrVal($name, "webhookFWinstance", "");
	if ($webhookHttpHostname eq "" || $hash->{WEBHOOK_URI} eq "" || $hash->{WEBHOOK_PORT} eq "") {
		readingsSingleUpdate ( $hash, "lastError", "Please (re)set 'webhookHttpHostname' and 'webhookFWinstance'", 1 );
		$hash->{WEBHOOK_REGISTER} = "incomplete_attributes";
		return;
	}

	my ($username, $password) = ALP600_getBasicAuth($hash);
	my $httpEventUrl = "http://" . $hash->{IP} . "/webs/netHttpEventCfgEx?"
						. "btest=0";
	# this is the way do disable it :-D
	if ($type ne "none") {
		$httpEventUrl .=  "&ckenable=1"
						. "&selproto=0"
						. "&addr=" . $webhookHttpHostname . ":" . $hash->{WEBHOOK_PORT}
						. "&req=" . $hash->{WEBHOOK_URI}
						. "&selmethod=0"
						. "&parname=" . "serial"
						. "&parval=" . $hash->{SERIAL}
						. "&info="
						;
	}

	HttpUtils_NonblockingGet({
		url         => $httpEventUrl,
		timeout     => 10,
		hash        => $hash,
		method      => "GET",
		user        => $username,
		pwd         => $password,
		callback    => sub($$$){}
	});

	my $ringEventUrl = "http://" . $hash->{IP} . "/cgi-bin/sensor_cgi?"
							. "action=set"
							. "&channel=0"
							. "&HttpSwitch=" . ($type eq "ring" || $type eq "both" ? "open" : "close")
							. "&HttpParam=" . "ring"
						;

	HttpUtils_NonblockingGet({
		url         => $ringEventUrl,
		timeout     => 10,
		hash        => $hash,
		method      => "GET",
		user        => $username,
		pwd         => $password,
		callback    => sub($$$){}
	});

	my $motionEventUrl = "http://" . $hash->{IP} . "/cgi-bin/motion_cgi?"
							. "action=set"
							. "&channel=0"
							. "&HttpSwitch=" . ($type eq "motion" || $type eq "both" ? "open" : "close")
							. "&HttpParam=" . "motion"
							. "&Time1Switch=open"
							. "&MotionSwitch=open"
						;

	HttpUtils_NonblockingGet({
		url         => $motionEventUrl,
		timeout     => 10,
		hash        => $hash,
		method      => "GET",
		user        => $username,
		pwd         => $password,
		callback    => sub($$$){}
	});

	$hash->{WEBHOOK_REGISTER} = "sent";

	# update status in 10 seconds ... this is enough, hopefully ;)
	InternalTimer( gettimeofday()+10, "ALP600_updateCallbackStatus", $hash, 0 );
}

#------------------------------------------------------------------------------------------------------
# calls the URL that would be called to inform the official AlphaGo ALP-600-App
#------------------------------------------------------------------------------------------------------
sub ALP600_notifyOfficialApp($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	return if (ALP600_isDisabled($hash));

	my $notifyOfficialApp = AttrVal($name, "notifyOfficialApp", "none");
	my $event = ReadingsVal($name, "event", "");

	return unless (($event eq "motion" && ($notifyOfficialApp eq "both" || $notifyOfficialApp eq "motion")) ||
	               ($event eq "ring"   && ($notifyOfficialApp eq "both" || $notifyOfficialApp eq "ring")));

	my $serial = $hash->{SERIAL};
	my $urlEvent = ($event eq "motion" ? "m" : "s");
	my $url = "http://5.175.1.2:50600/e?s=" . $serial . "&" . $urlEvent;

	ALP600_Log($hash, 1, "notifying official App ($url)!");
	HttpUtils_NonblockingGet({
		url         => $url,
		timeout     => 5,
		hash        => $hash,
		method      => "GET",
		callback    => sub($$$){
			my ($param, $err, $data) = @_;
			ALP600_Log($hash, 3, "REPLY: $err <> $data");
		}
	});
}


#------------------------------------------------------------------------------------------------------
# creates a new IPCAM device with the given nameOfDevice using known basicauth and setup
#------------------------------------------------------------------------------------------------------
sub ALP600_createIPCAMdevice($$)
{
	my ($hash, $nameOfDevice) = @_;
	my $name = $hash->{NAME};
	my $ip   = $hash->{IP};

	# define IPCAM device
	fhem("define " . $nameOfDevice . " IPCAM " . $ip) unless (IsDevice($nameOfDevice));

	if (IsDevice($nameOfDevice)) {
		return "Can't create, device $nameOfDevice already existing."
			unless (IsDevice($nameOfDevice, "IPCAM"));

		my ($username, $password) = ALP600_getBasicAuth($hash);
		fhem("attr ".$nameOfDevice." basicauth $username:$password")
			if ($username && $password);

		fhem("attr ".$nameOfDevice." comment Auto-created by $name")
			unless (defined($attr{$nameOfDevice}{comment}));

		fhem("attr ".$nameOfDevice." path cgi-bin/images_cgi?channel=0")
			unless (defined($attr{$nameOfDevice}{path}));

		fhem("attr ".$nameOfDevice." timestamp 1")
			unless (defined($attr{$nameOfDevice}{timestamp}));

		ALP600_Log($hash, 3, "created new device $nameOfDevice");
	}
}

#------------------------------------------------------------------------------------------------------
# request controller_cgi
#------------------------------------------------------------------------------------------------------
sub ALP600_requestControllerStatus($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	my ($username, $password) = ALP600_getBasicAuth($hash);
	my $url = "http://" . $hash->{IP} . "/cgi-bin/controller_cgi?action=get";
	HttpUtils_NonblockingGet({
		url         => $url,
		timeout     => 10,
		hash        => $hash,
		method      => "GET",
		user        => $username,
		pwd         => $password,
		callback    => \&ALP600_controllerStatusReceived,
	});
}
#------------------------------------------------------------------------------------------------------
# HttpUtils_NonblockingGet(controller_cgi) -> ALP600_controllerStatusReceived
#------------------------------------------------------------------------------------------------------
sub ALP600_controllerStatusReceived($$$)
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	my $name = $hash->{NAME};

	if ($err) {
		if ($err =~ m/wrong authentication/) {
			readingsSingleUpdate ( $hash, "lastError", "Please set username and password", 1 );
		}
		ALP600_Log($hash, 3, "error in controller_cgi: $err");
		return undef;
	}

	my %idleOnOutputs = map { $_ => 1 } split(",", AttrVal($name, "idleOnOutput", ""));

	my $switchToIdle = 0;
	my $controllerStatus = ALP600_splitIntoHash($data, "\n");

	readingsBeginUpdate($hash);
	for (my $i = 1; $i <= 3; $i++) {
		my $status = $controllerStatus->{"Status" . $i};
		readingsBulkUpdateIfChanged($hash, "output" . $i, $status);

		if (!$switchToIdle && $status == 1 && $idleOnOutputs{$i}) {
			$switchToIdle = 1;
		}
	}

	readingsBulkUpdate($hash, "state", "idle") if ($switchToIdle);

	readingsEndUpdate($hash, 1);
}

#------------------------------------------------------------------------------------------------------
# request systeminfo_cgi
#------------------------------------------------------------------------------------------------------
sub ALP600_requestSysteminfo($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	my ($username, $password) = ALP600_getBasicAuth($hash);
	my $url = "http://" . $hash->{IP} . "/cgi-bin/systeminfo_cgi";
	HttpUtils_NonblockingGet({
		url         => $url,
		timeout     => 10,
		hash        => $hash,
		method      => "GET",
		user        => $username,
		pwd         => $password,
		callback    => \&ALP600_systeminfoReceived,
	});
}

#------------------------------------------------------------------------------------------------------
# HttpUtils_NonblockingGet(systeminfo_cgi) -> ALP600_systeminfoReceived
#------------------------------------------------------------------------------------------------------
sub ALP600_systeminfoReceived($$$)
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	my $name = $hash->{NAME};

	if ($err) {
		if ($err =~ m/wrong authentication/) {
			readingsSingleUpdate ( $hash, "lastError", "Please set username and password", 1 );
		}
		ALP600_Log($hash, 3, "error in systeminfo_cgi: $err");
		return undef;
	}

	my $systeminfo = ALP600_splitIntoHash($data, "\n");

	readingsBeginUpdate($hash);
	for my $key (keys %{ $systeminfo }) {
		readingsBulkUpdate($hash, "SysInfo_".$key, $systeminfo->{$key});
	}
	readingsEndUpdate($hash, 1 );
}

#------------------------------------------------------------------------------------------------------
# request sysparam_cgi
#------------------------------------------------------------------------------------------------------
sub ALP600_requestSysparam($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	my ($username, $password) = ALP600_getBasicAuth($hash);
	my $url = "http://" . $hash->{IP} . "/cgi-bin/sysparam_cgi";
	HttpUtils_NonblockingGet({
		url         => $url,
		timeout     => 10,
		hash        => $hash,
		method      => "GET",
		user        => $username,
		pwd         => $password,
		callback    => \&ALP600_sysparamReceived,
	});
}

#------------------------------------------------------------------------------------------------------
# HttpUtils_NonblockingGet(sysparam_cgi) -> ALP600_sysparamReceived
#------------------------------------------------------------------------------------------------------
sub ALP600_sysparamReceived($$$)
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	my $name = $hash->{NAME};

	if ($err) {
		if ($err =~ m/wrong authentication/) {
			readingsSingleUpdate ( $hash, "lastError", "Please set username and password", 1 );
		}
		ALP600_Log($hash, 3, "error in sysparam_cgi: $err");
		return undef;
	}

	ALP600_Log($hash, 3, "$data");

	my $xmldata = ALP600_parseXML($hash, $data);
	return undef if (!$xmldata);

	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "SysParm_MACAddress", $xmldata->{'SysParam'}->{'SysNetwork'}->{'MACAddress'});
	readingsEndUpdate($hash, 1 );
}

#------------------------------------------------------------------------------------------------------
# Helper for BlockingGet
#------------------------------------------------------------------------------------------------------
sub ALP600_BlockingGet($$)
{
	my ($hash, $url) = @_;
	my $name = $hash->{NAME};

	my ($username, $password) = ALP600_getBasicAuth($hash);
	my ($err, $data) = HttpUtils_BlockingGet({
		url         => $url,
		timeout     => 5,
		hash        => $hash,
		method      => "GET",
		user        => $username,
		pwd         => $password,
	});

	if ($err) {
		if ($err =~ m/wrong authentication/) {
			readingsSingleUpdate ( $hash, "lastError", "Please set username and password", 1 );
		}
		ALP600_Log($hash, 3, "error in $url: $err");
		return ($err, undef);
	}

	return (undef, $data);
}

#------------------------------------------------------------------------------------------------------
# request callbacks
#------------------------------------------------------------------------------------------------------
sub ALP600_requestCallbacks($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	my %ret;

	# httpevent
	my ($err, $data) = ALP600_BlockingGet($hash, "http://" . $hash->{IP} . "/cgi-bin/httpevent_cgi?action=get");
	return $err if $err;

	$ret{"general"} = ALP600_splitIntoHash($data, "\n");

	# motion
	($err, $data) = ALP600_BlockingGet($hash, "http://" . $hash->{IP} . "/cgi-bin/motion_cgi?action=get");
	return $err if $err;

	$ret{"motion"} = ALP600_splitIntoHash($data, "\n");

	# sensor
	($err, $data) = ALP600_BlockingGet($hash, "http://" . $hash->{IP} . "/cgi-bin/sensor_cgi?action=get");
	return $err if $err;

	$ret{"ring"} = ALP600_splitIntoHash($data, "\n");

	return %ret;
}

#------------------------------------------------------------------------------------------------------
# ALP600_updateCallbackStatus
#------------------------------------------------------------------------------------------------------
sub ALP600_updateCallbackStatus($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	my %status = ALP600_requestCallbacks($hash);

	ALP600_Log($hash, 1, Dumper(\%status));

	# check general status
	if (!defined($status{"general"}) || 
	    !defined($status{"general"}{"Enable"}) ||
	    $status{"general"}{"Enable"}     ne "open" ||
	    $status{"general"}{"ParamName"}  ne "serial" ||
	    $status{"general"}{"ParamValue"} ne $hash->{SERIAL}) 
	{
		$hash->{WEBHOOK_REGISTER} = "disabled";
		return;
	}

	my $retval = "";

	# check that the webhook is for our instance
	my $expectedAddress = AttrVal($name, "webhookHttpHostname", "") . ":" . $hash->{WEBHOOK_PORT};
	my $expectedRequest = $hash->{WEBHOOK_URI};
	if ($status{"general"}{"Address"}  ne $expectedAddress ||
	    $status{"general"}{"Request"}  ne $expectedRequest)
	{
		$retval="[other instance]";
	}

	if (defined($status{"motion"}) && defined($status{"motion"}{"HttpSwitch"}) && $status{"motion"}{"HttpSwitch"} eq "open") {
		$retval .= "motion=enabled;"

	} else {
		$retval .= "motion=disabled;"
	}

	if (defined($status{"ring"}) && defined($status{"ring"}{"HttpSwitch"}) && $status{"ring"}{"HttpSwitch"} eq "open") {
		$retval .= "ring=enabled;"
	} else {
		$retval .= "ring=disabled;"
	}

	$hash->{WEBHOOK_REGISTER} = $retval;
}

#------------------------------------------------------------------------------------------------------
# ALP600_addExtension
#------------------------------------------------------------------------------------------------------
sub ALP600_addExtension($$$)
{
	my ($hash, $func, $link) = @_;
	my $name = $hash->{NAME};

	my $url = "/${link}";

	return 0 if ( defined( $data{FWEXT}{$url} ) && $data{FWEXT}{$url}{deviceName} ne $name );

	ALP600_Log($hash, 2, "Registering ALP600 for webhook URI $url ...");

	$data{FWEXT}{$url}{deviceName} = $name;
	$data{FWEXT}{$url}{FUNC}       = $func;
	$data{FWEXT}{$url}{LINK}       = $link;

	$hash->{fhem}{infix} = $link;

	return 1;
}

#------------------------------------------------------------------------------------------------------
# ALP600_removeExtension
#------------------------------------------------------------------------------------------------------
sub ALP600_removeExtension($)
{
	my ($hash) = @_;

	return unless defined($hash->{fhem}{infix});

	my $link = $hash->{fhem}{infix};

	my $url  = "/${link}";
	my $name = $data{FWEXT}{$url}{deviceName};

	ALP600_Log($hash, 2, "Unregistering ALP600 for webhook URL $url...");

	delete $data{FWEXT}{$url};
}

#------------------------------------------------------------------------------------------------------
# * if there is no SERIAL -> setup not complete
# * if it is a duplicate instance -> bah
# * if disabled -> ...
#------------------------------------------------------------------------------------------------------
sub ALP600_isDisabled($)
{
	my ($hash) = @_;
	return !$hash->{SERIAL} ||
	       $hash->{DUPLICATE_INSTANCE} ||
	       AttrVal($hash->{NAME}, "disable", "") ||
	       IsDisabled($hash->{NAME});
}

#------------------------------------------------------------------------------------------------------
#
#------------------------------------------------------------------------------------------------------
sub ALP600_parseXML($$)
{
	my ($hash, $data) = @_;
	my $name = $hash->{NAME};

	my $xml = new XML::Simple();
	my $xmldata = eval { $xml->XMLin($data, KeyAttr => [], ForceArray => 0) };
	if($@) {
		ALP600_Log($hash, 2, "XML error " . $@);
		return undef;
	}
	return $xmldata;
}

#------------------------------------------------------------------------------------------------------
# Requests the serial from the ALP (blocking)
#------------------------------------------------------------------------------------------------------
sub ALP600_blockingGetSerial($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my $ip   = $hash->{IP};

	my ($username, $password) = ALP600_getBasicAuth($hash);
	my $url = "http://" . $ip . "/cgi-bin/network_cgi?action=get";
	my ($err, $data) = HttpUtils_BlockingGet({
		url         => $url,
		timeout     => 5,
		hash        => $hash,
		method      => "GET",
		user        => $username,
		pwd         => $password,
	});

	# check authentication
	if ($err) {
		$hash->{STATE} = 'Error';
		readingsSingleUpdate($hash, "lastError", "Please set username and password", 1) if ($err =~ m/wrong authentication/);
		return undef;
	}

	#ALP600_Log($hash, 5, "data: $data);

	my $networkInfo = ALP600_splitIntoHash($data, "\n");

	# parse serial from mac
	my $mac = $networkInfo->{"MACAddress"};
	$mac =~ tr/-//d;
	return $mac;
}

#------------------------------------------------------------------------------------------------------
# Util: ALP600_resetToIdle
#------------------------------------------------------------------------------------------------------
sub ALP600_resetToIdle($)
{
	my ($hash) = @_;

	ALP600_Log($hash, 5, "called");
	RemoveInternalTimer($hash, "ALP600_resetToIdle");
	readingsSingleUpdate($hash, "state", "idle", 1);
}

#------------------------------------------------------------------------------------------------------
# Util: ALP600_splitIntoHash
#------------------------------------------------------------------------------------------------------
sub ALP600_splitIntoHash($$)
{
	my ($query, $divider) = @_;

	# stolen from GEOFENCY: extract values from URI
	my $retval;
	foreach my $pv ( split( $divider, $query ) ) {
		next if ( $pv eq "" );
		$pv =~ s/\+/ /g;
		$pv =~ s/%([\dA-F][\dA-F])/chr(hex($1))/ige;
		my ( $p, $v ) = split( "=", $pv, 2 );
		$v = "" if (!defined($v));
		$retval->{$p} = trim($v);
	}
	return $retval;
}

#------------------------------------------------------------------------------------------------------
# basic auth (username & password)
#------------------------------------------------------------------------------------------------------
sub ALP600_setBasicAuth($$)
{
	my ($hash,$password) = @_;
	ALP600_setKeyValue($hash, "passwd", $password);
}
sub ALP600_getBasicAuth($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	my $username = AttrVal($name, "username", "admin");

	my $password = ALP600_getKeyValue($hash, "passwd");
	return ($username, "") unless (defined($password));
	return ($username, $password);
}
sub ALP600_renameBasicAuth($$$)
{
	my ($newHash,$oldName,$newName) = @_;
	ALP600_renameKeyValue($newHash, $oldName, $newName, "passwd");
}
sub ALP600_deleteBasicAuth($)
{
	my ($hash) = @_;
	ALP600_deleteKeyValue($hash, "passwd");
}

#------------------------------------------------------------------------------------------------------
# Util: ALP600_setKeyValue
#------------------------------------------------------------------------------------------------------
sub ALP600_setKeyValue($$$)
{
	my ($hash,$subkey,$value) = @_;
	my $type = $hash->{TYPE};
	my $name = $hash->{NAME};

	my $key = "${type}_${name}_${subkey}";

	# always prepend passwords with '=' to allow to upgrade from having no
	# base64 encoding to using base64. decode_base64() ignores everything
	# after the '=' so if we try to decode a not decoded password (starting
	# with '='), this will result in an empty value which can be detected.
	$value = "=" . $value;

	# base64 encode if possible
	$value = encode_base64($value) if ($ALP600_hasMimeBase64);

	my $err = setKeyValue($key, $value);
	ALP600_Log($hash, 3, "Error when setting $key: $err") if ($err);
	return $err;
}

#------------------------------------------------------------------------------------------------------
# Util: ALP600_getKeyValue
#------------------------------------------------------------------------------------------------------
sub ALP600_getKeyValue($$)
{
	my ($hash,$subkey) = @_;
	my $type = $hash->{TYPE};
	my $name = $hash->{NAME};

	my $key = "${type}_${name}_${subkey}";
	my ($err, $value) = getKeyValue($key);

	# error
	if ($err) {
		ALP600_Log($hash, 3, "Error when fetching $key: $err");
		return undef;
	}

	# no value found
	return undef unless (defined($value));

	my $retval = $value;
	if ($ALP600_hasMimeBase64) {
		# try to base64-decode the retval.
		$retval = decode_base64($value);

		# if it is empty, it was not encoded (as decode_base64() ignores everything
		# after our initial '=')
		$retval = $value if ($retval eq "");
	}

	# our retval is always stored with a leading '='
	if ($retval !~ /^=.*/) {
		ALP600_Log($hash, 3, "failed to fetch retval");
		return undef;
	}

	# remove the leading '=' which was added in ALP600_setBasicAuth()
	return substr($retval, 1);
}

#------------------------------------------------------------------------------------------------------
# Util: ALP600_renameKeyValue
#------------------------------------------------------------------------------------------------------
sub ALP600_renameKeyValue($$$$)
{
	my ($newHash,$oldName,$newName,$subkey) = @_;
	my $type = $newHash->{TYPE};

	my $oldKey = "${type}_${oldName}_${subkey}";
	my $newKey = "${type}_${newName}_${subkey}";

	my ($err, $data) = getKeyValue($oldKey);
	return undef unless(defined($data));

	setKeyValue($newKey, $data);
	setKeyValue($oldKey, undef);
}

#------------------------------------------------------------------------------------------------------
# Util: ALP600_deleteKeyValue
#------------------------------------------------------------------------------------------------------
sub ALP600_deleteKeyValue($$)
{
	my ($hash,$subkey) = @_;
	my $type = $hash->{TYPE};
	my $name = $hash->{NAME};

	my $key = "${type}_${name}_${subkey}";
	my $err = setKeyValue($key, undef);
}

#------------------------------------------------------------------------------------------------------
# ALP600_isDevelopment - Used to enable development - features
#------------------------------------------------------------------------------------------------------
sub ALP600_isDevelopment()
{
	return AttrVal("global", "isDevelopment", "0") eq "1";
}

#------------------------------------------------------------------------------------------------------
# Util: Log
#------------------------------------------------------------------------------------------------------
sub ALP600_Log($$$)
{
	my ($hash, $logLevel, $logMessage) = @_;
	my $line       = ( caller(0) )[2];
	my $modAndSub  = ( caller(1) )[3];
	my $subroutine = ( split(':', $modAndSub) )[2];
	my $name       = ( ref($hash) eq "HASH" ) ? $hash->{NAME} : "ALP600";

	Log3($hash, $logLevel, "${name} (ALP600::${subroutine}:${line}) " . $logMessage);
	#Log3($hash, $logLevel, "${name} (ALP600::${subroutine}:${line}) Stack was: " . ALP600_getStacktrace());
}

#------------------------------------------------------------------------------------------------------
# Util: returns a stacktrace as a string (for debbugging)
#------------------------------------------------------------------------------------------------------
sub ALP600_getStacktrace($$$)
{
	my ($package, $filename, $line, $subroutine, $hasargs, $wantarray, $evaltext, $is_require, $hints, $bitmask, $hinthash);
	my $i = 2; # skip ALP600_getStacktrace() and ALP600_Log()
	my @r;
	my $retval = "";
	while (@r = caller($i)) {
		($package, $filename, $line, $subroutine, $hasargs, $wantarray, $evaltext, $is_require, $hints, $bitmask, $hinthash) = @r;
		$subroutine = ( split( ':', $subroutine ) )[2];
		$retval = "->${line}:${subroutine}${retval}";
		$i++;
	}
	return $retval;
}


# must be last
1;


=pod
=item device
=item summary    Module to controle the ALP-600 door bell
=item summary_DE Modul zur Steuerung der ALP-600 Türklingel

=begin html

<a name="ALP600"></a>
<h3>ALP600</h3>
<ul>
	<u><b>ALP600 - Controls the ALP-600 door bell</b></u><br>
	<br>
	<a name="ALP600define"></a>
	<b>Define</b><br>
	<br>
	<code>define &lt;name&gt; ALP600 &lt;IP&gt;</code><br>
	<br>
	<b>Example:</b><br>	<br>
	<code>define Frontdoor ALP600 192.168.2.177</code><br>
	<code>attr Frontdoor username myusername</code><br>
	<code>set Frontdoor password mysecretpassword</code><br>
	<br>
	This statement creates an ALP600 instance with the name Frontdoor with the IP 192.168.2.177.<br>
	After the device has been created, you need to set <i>password</i> (and <i>username</i>). Then the SERIAL will be requested from the device and you're ready to go.
	<br>
	<br>

	<a name="ALP600set"></a>
	<b>Set</b>
	<ul>
		<li><a name="activateOutput"></a>
			<dt><code><b>activateOutput [1|2|3]</b></code></dt>
			activates the alarm output on the base station (i.e. to open the door).
		</li>
		<li><a name="callback"></a>
			<dt><code><b>callback [both|ring|motion|none]</b></code></dt>
			sets the callback/webhook in the ALP-600 device. When set, the device will inform fhem on ring- and/or motion-events.
			Also see <i>webhookFWinstance</i> and <i>webhookHttpHostname</i> attributes.
		</li>
		<li><a name="createIPCAMdevice"></a>
			<dt><code><b>createIPCAMdevice &lt;name&gt;</b></code></dt>
			creates an IPCAM device with the given &lt;name&gt; to retrieve images from the ALP-600.
		</li>
		<li><a name="password"></a>
			<dt><code><b>password</b></code></dt>
			sets the password to connect to the ALP-600 and stores it in the filesystem (base64-encoded if you have MIME::Base64 installed).
		</li>
		<li><a name="requestSystemInfo"></a>
			<dt><code><b>requestSystemInfo</b></code></dt>
			retrieve details about the ALP-600.
		</li>
		<li><a name="requestSysParam"></a>
			<dt><code><b>requestSysParam</b></code></dt>
			retrieve other details about the ALP-600. Only available if <i>XML::Simple</i> is installed.
		</li>
	</ul>
	<br>

	<a name="ALP600attribut"></a>
	<b>Attributes</b>
	<ul>
		<li><a name="disable"></a>
			<dt><code><b>disable</b></code></dt>
			disables this ALP-600-instance
		</li>
		<li><a name="idleDoorContact"></a>
			<dt><code><b>idleDoorContact &lt;device&gt;:&lt;eventRegExp&gt;</b></code></dt>
			use a door contact to reset this ALP-600 instance to <code>idle</code> when the door is opened. Example: <code>attr &lt;name&gt; idleDoorContact EG_Haustuer:state:.open</code>.
		</li>
		<li><a name="idleOnOutput"></a>
			<dt><code><b>idleOnOutput [1,2,3]</b></code></dt>
			select one or more outputs (1, 2, 3) of the ALP-600 that set this instance to <code>idle</code> when activated. This can be used to reset to <code>idle</code> when the door-opener is triggered via the ALP-600. This only works if <code>outputCheckInterval</code> is enabled!
		</li>
		<li><a name="idleTimeout"></a>
			<dt><code><b>idleTimeout &lt;seconds&gt;</b></code></dt>
			the state of this ALP-600 instance will return to <code>idle</code> after this interval. If set to <code>0</code>, the state will not change back automatically (this is the old behaviour) (default: 30)
		</li>
		<li><a name="notifyOfficialApp"></a>
			<dt><code><b>notifyOfficialApp [both|ring|motion|none]</b></code></dt>
			if set to <code>both</code>, <code>ring</code> or <code>motion</code>, the official AlphaGo ALP-600 iOS App gets notified on the given event and rings. If your ALP-600 has a very current firmware-version, this is probably not needed.<br>
			<b>Attention:</b><br>
			To set this up, you have to do the following steps, in order:
			<ol>
			<li>Configure the ALP-600 iOS App (IP-Address, Credentials, ...) </li>
			<li>Enable Push-Notifications</li>
			<li>Save settings</li>
			<li>In FHEM: <code>set &lt;name&gt; callback [both|ring|motion]</code></li>
			</ol>
		</li>
		<li><a name="outputCheckInterval"></a>
			<dt><code><b>outputCheckInterval &lt;seconds&gt;</b></code></dt>
			interval to check the outputs (relais) of the ALP-600. If set to 0, checks are disabled (default 0).
			For each output a new reading <code>outputN</code> will be created beeing 0 or 1.
		</li>
		<li><a name="pingInterval"></a>
			<dt><code><b>pingInterval &lt;seconds&gt;</b></code></dt>
			interval to ping the ALP-600 outdoor station. If set to 0, ping is disabled (default 0). Only available if <i>Net::Ping</i> is installed.
		</li>
		<li><a name="username"></a>
			<dt><code><b>username</b></code></dt>
			set the username to connect to the ALP-600 (default 'admin'). For the password, see <code>set &lt;name&gt; password ...</code>.
		</li>
		<li><a name="webhookFWinstance"></a>
			<dt><code><b>webhookFWinstance</b></code></dt>
			The webinstance used when setting the callback/webhook in the ALP-600
		</li>
		<li><a name="webhookHttpHostname"></a>
			<dt><code><b>webhookHttpHostname</b></code></dt>
			The IP or FQDN of the FHEM Server used when setting the callback/webhook in the ALP-600
		</li>
	</ul>
	<br>

	<a name="ALP600readings"></a>
	<b>Readings</b>
	<ul>
		<li><a name="event"></a>
			<dt><code><b>event</b></code></dt>
			contains the last event that was triggered by the ALP-600. (<code>motion</code> or <code>ring</code>).
		</li>
		<li><a name="motion"></a>
			<dt><code><b>motion</b></code></dt>
			the timestamp of the last <code>motion</code> event triggered by the ALP-600.
		</li>
		<li><a name="ping"></a>
			<dt><code><b>ping</b></code></dt>
			The ping status of the ALP-600 (<code>disabled</code>, <code>ok</code> or <code>unreachable</code>). See attribute <i>pingInterval</i>.
		</li>
		<li><a name="ring"></a>
			<dt><code><b>ring</b></code></dt>
			the timestamp of the last <code>ring</code> event triggered by the ALP-600.
		</li>
	</ul>
</ul>

=end html
# =begin html_DE
#
#
# =end html_DE
=cut
