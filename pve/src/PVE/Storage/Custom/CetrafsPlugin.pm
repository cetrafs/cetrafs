# SPDX-License-Identifier: AGPL-3.0-or-later
# Florian Paul Azim Hoberg @gyptazy <contact@gyptazy.com>
#
# Proxmox VE storage plugin for cetrafs: storage type "cetrafs".
#
# A cetrafs volume on a shared LUN, mounted at the same path on every node
# and used like a directory storage -- VM images (raw/qcow2/vmdk), container
# volumes, ISOs, templates, backups and snippets are plain files on it. The
# storage is mounted on demand (activate_storage, which pvestatd calls on
# every node), the same way PVE's own NFS/CIFS plugins mount theirs.
#
# The volume itself is created once, outside PVE, with mkfs.cetra.

package PVE::Storage::Custom::CetrafsPlugin;

use strict;
use warnings;

use File::Path qw(make_path);
use PVE::ProcFSTools;
use PVE::Tools qw(run_command);
use PVE::Storage::Plugin;
use base qw(PVE::Storage::Plugin);

my $MIN_APIVER = 2;
my $MAX_APIVER = 15;

# Every node mounts the same LUN: let PVE treat the storage as shared (live
# migration without copying disks, HA) without the user having to set it.
push @PVE::Storage::Plugin::SHARED_STORAGE, 'cetrafs'
    if !grep { $_ eq 'cetrafs' } @PVE::Storage::Plugin::SHARED_STORAGE;

# Plugin registration
sub api {
    my $apiver = eval { PVE::Storage::APIVER() };
    return $apiver if defined($apiver) && $apiver >= $MIN_APIVER && $apiver <= $MAX_APIVER;
    return $MAX_APIVER;
}

sub type {
    return 'cetrafs';
}

sub plugindata {
    return {
        content => [
            {
                images => 1,
                rootdir => 1,
                iso => 1,
                vztmpl => 1,
                backup => 1,
                snippets => 1,
                none => 1,
            },
            { images => 1 },
        ],
        format => [{ raw => 1, qcow2 => 1, vmdk => 1 }, 'raw'],
        'sensitive-properties' => {},
    };
}

# Properties are global across all storage types; only the cetrafs-specific
# ones are registered here, the rest (path, options, ...) are PVE's own.
sub properties {
    return {
        'cetrafs-device' => {
            description => "The shared block device holding the cetrafs volume. Use a "
                . "path that names the same LUN on every node, e.g. "
                . "/dev/disk/by-id/... or a multipath alias in /dev/mapper.",
            type => 'string',
            format => 'pve-storage-path',
        },
        'cetrafs-nofilelock' => {
            description => "Mount with 'nofilelock': no cross-node exclusive open lock, "
                . "so an image can be open on two nodes during a live migration "
                . "handoff. Every node of the cluster must mount with the same "
                . "mode; a change takes effect once all nodes have unmounted.",
            type => 'boolean',
            default => 1,
        },
    };
}

sub options {
    return {
        'cetrafs-device' => { fixed => 1 },
        'cetrafs-nofilelock' => { optional => 1 },
        path => { fixed => 1, optional => 1 },
        options => { optional => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        shared => { optional => 1 },
        content => { optional => 1 },
        format => { optional => 1 },
        preallocation => { optional => 1 },
        'prune-backups' => { optional => 1 },
        'max-protected-backups' => { optional => 1 },
        'content-dirs' => { optional => 1 },
        'create-base-path' => { optional => 1 },
        'create-subdirs' => { optional => 1 },
        bwlimit => { optional => 1 },
    };
}

# Like the NFS/CIFS plugins: mount below /mnt/pve unless told otherwise.
sub check_config {
    my ($class, $sectionId, $config, $create, $skipSchemaCheck) = @_;

    $config->{path} = "/mnt/pve/$sectionId" if $create && !$config->{path};

    return $class->SUPER::check_config($sectionId, $config, $create, $skipSchemaCheck);
}

# Mount handling
sub mountpoint_of {
    my ($scfg) = @_;
    my $path = $scfg->{path};
    $path =~ s|/+$|| if length($path) > 1;
    return $path;
}

# The fstype mounted at $path, or undef. The device is not compared:
# /proc/mounts names it canonically (/dev/dm-3, /dev/sdc), not by the
# by-id or multipath alias path that is configured.
sub mounted_fstype {
    my ($path, $mountdata) = @_;
    my $fstype;
    # The last entry wins, it is the one on top.
    for my $entry (@$mountdata) {
        $fstype = $entry->[2] if $entry->[1] eq $path;
    }
    return $fstype;
}

sub cetrafs_is_mounted {
    my ($scfg, $mountdata) = @_;
    my $fstype = mounted_fstype(mountpoint_of($scfg), $mountdata);
    return defined($fstype) && $fstype eq 'cetrafs' ? 1 : 0;
}

sub mount_options {
    my ($scfg) = @_;
    my @opts;
    push @opts, 'nofilelock' if $scfg->{'cetrafs-nofilelock'} // 1;
    push @opts, $scfg->{options} if $scfg->{options};
    return @opts;
}

sub cetrafs_mount {
    my ($storeid, $scfg) = @_;

    my $device = $scfg->{'cetrafs-device'};
    my $path = mountpoint_of($scfg);

    my $cmd = ['/bin/mount', '-t', 'cetrafs'];
    my @opts = mount_options($scfg);
    push @$cmd, '-o', join(',', @opts) if @opts;
    push @$cmd, $device, $path;

    eval { run_command($cmd, errmsg => "mount error") };
    if (my $err = $@) {
        # The kernel says why in the log only; point at the usual causes.
        die "cetrafs storage '$storeid': mounting '$device' on '$path' failed: $err"
            . "Check 'dmesg' on this node. Common causes: the cetrafs module is not "
            . "installed (cetrafs-dkms), the device holds no cetrafs volume (mkfs.cetra), "
            . "another node mounted it with a different file lock mode (nofilelock), or "
            . "the device has no atomic COMPARE AND WRITE and is mounted elsewhere.\n";
    }
}

# Storage
sub check_connection {
    my ($class, $storeid, $scfg) = @_;
    return -b $scfg->{'cetrafs-device'} ? 1 : 0;
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{mountdata} //= PVE::ProcFSTools::parse_proc_mounts();

    if (!cetrafs_is_mounted($scfg, $cache->{mountdata})) {
        my $device = $scfg->{'cetrafs-device'};
        my $path = mountpoint_of($scfg);

        die "cetrafs storage '$storeid': '$device' is not a block device\n" if !-b $device;

        my $other = mounted_fstype($path, $cache->{mountdata});
        die "cetrafs storage '$storeid': '$path' already has a '$other' file system mounted\n"
            if defined($other);

        make_path($path);
        cetrafs_mount($storeid, $scfg);

        $cache->{mountdata} = PVE::ProcFSTools::parse_proc_mounts();
    }

    return $class->SUPER::activate_storage($storeid, $scfg, $cache);
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{mountdata} //= PVE::ProcFSTools::parse_proc_mounts();

    if (cetrafs_is_mounted($scfg, $cache->{mountdata})) {
        run_command(['/bin/umount', mountpoint_of($scfg)], errmsg => 'umount error');
        delete $cache->{mountdata};
    }

    return;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{mountdata} //= PVE::ProcFSTools::parse_proc_mounts();

    # Not mounted: report it as inactive rather than the root file system's
    # usage of the empty mount point.
    return undef if !cetrafs_is_mounted($scfg, $cache->{mountdata});

    return $class->SUPER::status($storeid, $scfg, $cache);
}

1;
