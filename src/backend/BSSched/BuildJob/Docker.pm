# Copyright (c) 2017 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program (see the file COPYING); if not, write to the
# Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
#

package BSSched::BuildJob::Docker;

use strict;
use warnings;

use Data::Dumper;
use Build;
use BSUtil;
use BSSolv;
use BSConfiguration;
use BSUrlmapper;
use BSSched::DoD;       	# for dodcheck


=head1 NAME

BSSched::BuildJob::Docker - A Class to handle Docker and Fissile image builds

=head1 SYNOPSIS

my $h = BSSched::BuildJob::Docker->new()

$h->check();

$h->expand();

$h->rebuild();

=cut


=head2 new - TODO: add summary

 TODO: add description

=cut

sub new {
  return bless({}, $_[0]);
}


=head2 expand - TODO: add summary

 TODO: add description

=cut

sub expand {
  return 1, splice(@_, 3);
}

=head2 check - TODO: add summary

 TODO: add description

=cut

sub maptoremote {
  my ($proj, $projid, $repoid) = @_; 
  $repoid = defined($repoid) ? "/$repoid" : '';
  return "$proj->{'root'}:$projid$repoid" unless $proj->{'remoteroot'};
  return "$proj->{'root'}$repoid" if $projid eq $proj->{'remoteroot'};
  return undef if $projid !~ /^\Q$proj->{'remoteroot'}\E:(.*)$/;
  return "$proj->{'root'}:$1$repoid";
}

sub check {
  my ($self, $ctx, $packid, $pdata, $info, $buildtype) = @_;

  my $gctx = $ctx->{'gctx'};
  my $myarch = $gctx->{'arch'};
  my $projid = $ctx->{'project'};
  my $repoid = $ctx->{'repository'};
  my $prp = $ctx->{'prp'};
  my $repo = $ctx->{'repo'};

  my $notready = $ctx->{'notready'};
  my $prpnotready = $gctx->{'prpnotready'};
  my $neverblock = $ctx->{'isreposerver'} || ($repo->{'block'} || '' eq 'never');

  my @deps = @{$info->{'dep'} || []};
  my @cbdep;
  my @cmeta;
  my $expanddebug = $ctx->{'expanddebug'};

  my @containerdeps = grep {/^container:/} @deps;
  if (@containerdeps) {
    @deps = grep {!/^container:/} @deps;

    # setup container pool
    my $cpool = $ctx->{'pool'};

    # expand to container package name
    my $xp = BSSolv::expander->new($cpool, $ctx->{'conf'});
    my ($cok, @cdeps) = $xp->expand(@containerdeps);
    BSSched::BuildJob::add_expanddebug($ctx, 'container expansion', $xp, $cpool) if $expanddebug;
    return ('unresolvable', join(', ', @cdeps)) unless $cok;
    return ('unresolvable', 'weird result of container expansion') unless @cdeps > 0 && @cdeps <= @containerdeps;

    my ($lastbdep, $lastp);
    for my $cdep (@cdeps) {
      # find container package
      my $p;
      for ($cpool->whatprovides($cdep)) {
        $p = $_ if $cpool->pkg2name($_) eq $cdep;
      }
      return ('unresolvable', 'weird result of container expansion') unless $p;

      # generate bdep entry
      my $cbdep = {'name' => $cdep, 'noinstall' => 1};
      my $cprp = $cpool->pkg2reponame($p);
      push @cmeta, $cpool->pkg2pkgid($p) . "  $cprp/$cdep";
      ($cbdep->{'project'}, $cbdep->{'repository'}) = split('/', $cprp, 2);
      if ($ctx->{'dobuildinfo'}) {
        my $d = $cpool->pkg2data($p);
        $cbdep->{'epoch'} = $d->{'epoch'} if $d->{'epoch'};
        $cbdep->{'version'} = $d->{'version'};
        $cbdep->{'release'} = $d->{'release'} if defined $d->{'release'};
        $cbdep->{'arch'} = $d->{'arch'} if $d->{'arch'};
        $cbdep->{'hdrmd5'} = $d->{'hdrmd5'} if $d->{'hdrmd5'};
      }
      push @cbdep, $cbdep;
      $lastbdep = $cbdep;
      $lastp = $p;
    }

    # append container repositories to path
    my @infopath = @{$info->{'path'} || []};
    splice(@infopath, -$info->{'extrapathlevel'}) if $info->{'extrapathlevel'};
    my $haveobsrepositories = grep {$_->{'project'} eq '_obsrepositories'} @infopath;
    my @newpath;
    my $annotation = BSSched::BuildJob::getcontainerannotation($cpool, $lastp, $lastbdep);
    if (!$annotation && !$haveobsrepositories) {
      # no annotation, assume obsrepositories:/
      push @newpath, {'project' => '_obsrepositories', 'repository' => ''};
    } elsif ($annotation && !$haveobsrepositories) {
      # map all repos and add to path
      my $remoteprojs = $gctx->{'remoteprojs'} || {};
      my $rproj = $remoteprojs->{$lastbdep->{'project'}};
      undef $rproj if $rproj && !defined($rproj->{'root'});	# no partitions
      for my $r (@{$annotation->{'repo'} || []}) {
	my $url = $r->{'url'};
	next unless $url;
	# see Build::Kiwi
	my $urlprp;
	if ($url eq 'obsrepositories:/') {
	  $urlprp = '_obsrepositories/';
	} elsif ($url =~ /^obs:\/{1,3}([^\/]+)\/([^\/]+)\/?$/) {
	  $urlprp = "$1/$2";
	  $urlprp = maptoremote($rproj, $1, $2) if $rproj;
	} else {
	  if ($Build::Kiwi::urlmapper) {
	    $urlprp = $Build::Kiwi::urlmapper->($url);
	  } else {
	    $ctx->{'urlmappercache'} ||= {};
	    $urlprp = BSUrlmapper::urlmapper($url, $ctx->{'urlmappercache'});
	  }
	}
	# if we can't map fall back to project/repository element from annotation
	if (!$urlprp && $r->{'project'} && $r->{'repository'}) {
	  $urlprp = "$r->{'project'}/$r->{'repository'}";
	  $urlprp = maptoremote($rproj, $r->{'project'}, $r->{'repository'}) if $rproj;
	}
	return ('broken', "repository url '$url' cannot be handled") unless $urlprp;
	my ($pr, $rp) = split('/', $urlprp, 2);
	push @newpath, {'project' => $pr, 'repository' => $rp};
	$newpath[-1]->{'priority'} = $r->{'priority'} if defined $r->{'priority'};
      }
    }
    my $r = $ctx->append_info_path($info, \@newpath);
    return ('delayed', 'remotemap entry missing') unless $r;
  }
  
  
  my %aprpprios;
  my @aprps = BSSched::BuildJob::expandkiwipath($ctx, $info, \%aprpprios);

  # get config from docker path
  my @configpath = @aprps;
  # always put ourselfs in front
  unshift @configpath, "$projid/$repoid" unless @configpath && $configpath[0] eq "$projid/$repoid";
  my $bconf = $ctx->getconfig($projid, $repoid, $myarch, \@configpath);
  if (!$bconf) {
    if ($ctx->{'verbose'}) {
      print "      - $packid ($buildtype)\n";
      print "        no config\n";
    }
    return ('broken', 'no config');
  }
  $bconf->{'type'} = 'docker';
  $bconf->{'no_vminstall_expand'} = 1 if @{$repo->{'path'} || []};

  my $pool = BSSolv::pool->new();
  $pool->settype('deb') if $bconf->{'binarytype'} eq 'deb';
  $pool->settype('arch') if $bconf->{'binarytype'} eq 'arch';
  $pool->setmodules($bconf->{'modules'}) if $bconf->{'modules'} && defined &BSSolv::pool::setmodules;

  my $delayed_errors = '';
  for my $aprp (@aprps) {
    if (!$ctx->checkprpaccess($aprp)) {
      if ($ctx->{'verbose'}) {
        print "      - $packid ($buildtype)\n";
        print "        repository $aprp is unavailable";
      }
      return ('broken', "repository $aprp is unavailable");
    }
    my $r = $ctx->addrepo($pool, $aprp);
    if (!$r) {
      my $error = "repository '$aprp' is unavailable";
      if (defined $r) {
	$error .= " (delayed)";
	$delayed_errors .= ", $error";
	next;
      }
      if ($ctx->{'verbose'}) {
        print "      - $packid ($buildtype)\n";
        print "        $error\n";
      }
      return ('broken', $error);
    }
  }
  return ('delayed', substr($delayed_errors, 2)) if $delayed_errors;

  my $unorderedrepos = 0;
  if (!grep {$_->{'project'} eq '_obsrepositories'} @{$info->{'path'} || []}) {
    if ($bconf->{"expandflags:unorderedimagerepos"} || grep {$_ eq '--unorderedimagerepos'} @{$info->{'dep'} || []}) {
      $unorderedrepos = 1;
    }
  }
  if ($unorderedrepos) {
    return ('broken', 'perl-BSSolv does not support unordered repos') unless defined &BSSolv::repo::setpriority;
    $_->setpriority($aprpprios{$_->name()} || 0) for $pool->repos();
    $pool->createwhatprovides(1);
  } else {
    $pool->createwhatprovides();
  }

  my $bconfignore = $bconf->{'ignore'};
  my $bconfignoreh = $bconf->{'ignoreh'};
  delete $bconf->{'ignore'};
  delete $bconf->{'ignoreh'};

  local $Build::expand_dbg = 1 if $expanddebug;
  my $xp = BSSolv::expander->new($pool, $bconf);
  no warnings 'redefine';
  local *Build::expand = sub { $_[0] = $xp; goto &BSSolv::expander::expand; };
  use warnings 'redefine';
  my ($eok, @edeps) = Build::get_build($bconf, [], @deps, '--ignoreignore--');
  BSSched::BuildJob::add_expanddebug($ctx, 'docker image expansion', $xp, $pool) if $expanddebug;
  if (!$eok) {
    if ($ctx->{'verbose'}) {
      print "      - $packid ($buildtype)\n";
      print "        unresolvable:\n";
      print "            $_\n" for @edeps;
    }
    return ('unresolvable', join(', ', @edeps));
  }
  $bconf->{'ignore'} = $bconfignore if $bconfignore;
  $bconf->{'ignoreh'} = $bconfignoreh if $bconfignoreh;

  my @new_meta;

  my %dep2pkg;
  for my $p ($pool->consideredpackages()) {
    my $n = $pool->pkg2name($p);
    $dep2pkg{$n} = $p;
  }

  my %nrs;
  for my $arepo ($pool->repos()) {
    my $aprp = $arepo->name();
    if ($neverblock) {
      $nrs{$aprp} = {};
    } else {
      $nrs{$aprp} = ($prp eq $aprp ? $notready : $prpnotready->{$aprp}) || {};
    }
  }

  my @blocked;
  for my $n (sort @edeps) {
    my $p = $dep2pkg{$n};
    my $aprp = $pool->pkg2reponame($p);
    push @blocked, $prp ne $aprp ? "$aprp/$n" : $n if $nrs{$aprp}->{$n};
    push @new_meta, $pool->pkg2pkgid($p)."  $aprp/$n" unless @blocked;
  }
  if (@blocked) {
    splice(@blocked, 10, scalar(@blocked), '...') if @blocked > 10;
    if ($ctx->{'verbose'}) {
      print "      - $packid ($buildtype)\n";
      print "        blocked (@blocked)\n";
    }
    return ('blocked', join(', ', @blocked));
  }
  push @new_meta, @cmeta;
  @new_meta = sort {substr($a, 34) cmp substr($b, 34)} @new_meta;
  unshift @new_meta, map {"$_->{'srcmd5'}  $_->{'project'}/$_->{'package'}"} @{$info->{'extrasource'} || []};
  my ($state, $data) = BSSched::BuildJob::metacheck($ctx, $packid, $pdata, $buildtype, \@new_meta, [ $bconf, \@edeps, $pool, \%dep2pkg, \@cbdep, $unorderedrepos]);
  if ($state eq 'scheduled') {
    my $dods = BSSched::DoD::dodcheck($ctx, $pool, $myarch, @edeps);
    return ('blocked', $dods) if $dods;
    $dods = BSSched::DoD::dodcheck($ctx, $ctx->{'pool'}, $myarch, map {$_->{'name'}} @cbdep);
    return ('blocked', $dods) if $dods;
  }
  return ($state, $data);
}

=head2 add_container_deps - add container data to the cloned context

 TODO: add description

=cut

sub add_container_deps {
  my ($ctx, $cbdep) = @_;
  return unless @{$cbdep || []};
  push @{$ctx->{'extrabdeps'}}, @$cbdep;
  $ctx->{'containerpath'} = [ BSUtil::unify(map {"$_->{'project'}/$_->{'repository'}"} @$cbdep) ];
  $ctx->{'containerannotation'} = delete $_->{'annotation'} for @$cbdep;
}

=head2 build - TODO: add summary

 TODO: add description

=cut

sub build {
  my ($self, $ctx, $packid, $pdata, $info, $data) = @_;
  my $bconf = $data->[0];	# this is the config used to expand the image packages
  my $edeps = $data->[1];
  my $epool = $data->[2];
  my $edep2pkg = $data->[3];
  my $cbdep = $data->[4];
  my $unorderedrepos = $data->[5];
  my $reason = $data->[6];

  my $gctx = $ctx->{'gctx'};
  my $projid = $ctx->{'project'};
  my $repoid = $ctx->{'repository'};
  my $repo = $ctx->{'repo'};

  if (!@{$repo->{'path'} || []}) {
    # repo has no path, use docker repositories also for docker system setup
    my $xp = BSSolv::expander->new($epool, $bconf);
    no warnings 'redefine';
    local *Build::expand = sub { $_[0] = $xp; goto &BSSolv::expander::expand; };
    use warnings 'redefine';
    $ctx = bless { %$ctx, 'conf' => $bconf, 'prpsearchpath' => [], 'pool' => $epool, 'dep2pkg' => $edep2pkg, 'realctx' => $ctx, 'expander' => $xp, 'unorderedrepos' => $unorderedrepos}, ref($ctx);
    add_container_deps($ctx, $cbdep);
    return BSSched::BuildJob::create($ctx, $packid, $pdata, $info, [], $edeps, $reason, 0);
  }

  # clone the ctx so we can change it
  $ctx = bless { %$ctx, 'realctx' => $ctx}, ref($ctx);
  
  if ($ctx->{'dobuildinfo'} || $unorderedrepos) {
    # need to dump the image packages first...
    my @bdeps;
    for my $n (@$edeps) {
      my $b = {'name' => $n};
      my $p = $edep2pkg->{$n};
      my $d = $epool->pkg2data($p);
      my $prp = $epool->pkg2reponame($p);
      ($b->{'project'}, $b->{'repository'}) = split('/', $prp, 2) if $prp;
      if ($ctx->{'dobuildinfo'}) {
        $b->{'epoch'} = $d->{'epoch'} if $d->{'epoch'};
        $b->{'version'} = $d->{'version'};
        $b->{'release'} = $d->{'release'} if defined $d->{'release'};
        $b->{'arch'} = $d->{'arch'} if $d->{'arch'};
      }
      $b->{'noinstall'} = 1;
      push @bdeps, $b;
    }
    $ctx->{'extrabdeps'} = \@bdeps;
    $edeps = [];
  }

  add_container_deps($ctx, $cbdep);

  # repo has a configured path, expand docker build system with it
  return BSSched::BuildJob::create($ctx, $packid, $pdata, $info, [], $edeps, $reason, 0);
}

1;
