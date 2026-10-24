# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Proxmox VE integration: the storage plugin (type "cetrafs") and its
# optional web UI. Nothing is compiled; install-* only copy files.
#
#   make -C pve install-plugin    # on every PVE node
#   make -C pve install-ui        # optional, on every node serving the web UI
#
# Packaged as pve-storage-cetrafs and pve-storage-cetrafs-ui by `make deb`.

DESTDIR ?=
CUSTOMDIR := $(DESTDIR)/usr/share/perl5/PVE/Storage/Custom
SRCDIR := src/PVE/Storage/Custom

UIJSDIR := $(DESTDIR)/usr/share/pve-manager/js
UIHOOKDIR := $(DESTDIR)/usr/share/pve-storage-cetrafs
APTCONFDIR := $(DESTDIR)/etc/apt/apt.conf.d

.PHONY: all install install-plugin install-ui uninstall-plugin uninstall-ui reload

# Nothing to build. Keeps a bare "make" from installing.
all:

install: install-plugin install-ui

install-plugin:
	install -d $(CUSTOMDIR)
	install -m 0644 $(SRCDIR)/CetrafsPlugin.pm $(CUSTOMDIR)/
ifeq ($(DESTDIR),)
	$(MAKE) reload
endif

# With a DESTDIR (packaging), the Debian package runs the hook from its
# postinst and a dpkg trigger on the index template instead of the apt hook.
install-ui:
	install -d $(UIJSDIR) $(UIHOOKDIR)
	install -m 0644 ui/cetrafs.js $(UIJSDIR)/
	install -m 0755 ui/pve-ui-hook $(UIHOOKDIR)/
ifeq ($(DESTDIR),)
	install -d $(APTCONFDIR)
	install -m 0644 ui/99pve-storage-cetrafs-ui $(APTCONFDIR)/
	$(UIHOOKDIR)/pve-ui-hook install
endif

uninstall-plugin:
	rm -f $(CUSTOMDIR)/CetrafsPlugin.pm
	$(MAKE) reload

uninstall-ui:
	-$(UIHOOKDIR)/pve-ui-hook remove
	rm -f $(APTCONFDIR)/99pve-storage-cetrafs-ui
	rm -f $(UIJSDIR)/cetrafs.js
	rm -f $(UIHOOKDIR)/pve-ui-hook
	-rmdir $(UIHOOKDIR)

# PVE loads storage plugins when its daemons start.
reload:
	for s in pvedaemon pveproxy pvestatd pvescheduler; do \
	  systemctl try-reload-or-restart $$s.service || true; \
	done
