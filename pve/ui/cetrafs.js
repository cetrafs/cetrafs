// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Web UI integration for the cetrafs storage plugin.
//
// Adds "cetrafs" to Datacenter -> Storage -> Add, and the matching edit
// dialog. The volume is created once with mkfs.cetra; the storage then
// mounts it on every node by itself.
//
// Loaded by a <script> tag after pvemanagerlib.js, see ui/pve-ui-hook.

Ext.define('PVE.storage.CetrafsInputPanel', {
    extend: 'PVE.panel.StorageBase',

    // The plugin mounts with nofilelock unless told otherwise, so a storage
    // added on the command line without the key must show it as checked.
    setValues: function (values) {
        let me = this;
        if (values && values['cetrafs-nofilelock'] === undefined) {
            values['cetrafs-nofilelock'] = 1;
        }
        return me.callParent([values]);
    },

    initComponent: function () {
        let me = this;

        me.column1 = [
            {
                xtype: me.isCreate ? 'proxmoxtextfield' : 'displayfield',
                name: 'cetrafs-device',
                fieldLabel: gettext('Device'),
                emptyText: '/dev/disk/by-id/...',
                allowBlank: false,
            },
            {
                xtype: me.isCreate ? 'proxmoxtextfield' : 'displayfield',
                name: 'path',
                fieldLabel: gettext('Mount point'),
                emptyText: '/mnt/pve/<' + gettext('ID') + '>',
                allowBlank: true,
            },
            {
                xtype: 'pveContentTypeSelector',
                cts: ['images', 'rootdir', 'iso', 'vztmpl', 'backup', 'snippets'],
                fieldLabel: gettext('Content'),
                name: 'content',
                value: ['images'],
                multiSelect: true,
                allowBlank: false,
            },
        ];

        me.column2 = [
            {
                xtype: 'proxmoxcheckbox',
                name: 'cetrafs-nofilelock',
                checked: true,
                uncheckedValue: 0,
                fieldLabel: gettext('No file lock'),
                autoEl: {
                    tag: 'div',
                    'data-qtip': gettext(
                        'Mount with nofilelock, needed for live migration. Every node must use the same mode; a change takes effect once the storage was unmounted on all nodes.',
                    ),
                },
            },
        ];

        if (me.isCreate) {
            me.columnB = [
                {
                    xtype: 'displayfield',
                    userCls: 'pmx-hint',
                    value: gettext(
                        'Create the volume once with mkfs.cetra first. The device path must name the same shared LUN on every node, e.g. /dev/disk/by-id/... or a multipath alias; the storage is then mounted on all nodes automatically.',
                    ),
                },
            ];
        }

        me.callParent();
    },
});

(function () {
    if (typeof PVE === 'undefined' || !PVE.Utils || !PVE.Utils.storageSchema) {
        return;
    }

    let entry = {
        name: 'cetrafs',
        ipanel: 'CetrafsInputPanel',
        faIcon: 'building',
        backups: true,
    };

    // The Add menu follows the schema's key order: put the entry right after
    // the other shared file systems by moving all later keys behind it. The
    // object itself is kept, other code may hold a reference to it.
    let schema = PVE.Utils.storageSchema;
    delete schema.cetrafs;

    let types = Object.keys(schema);
    let anchor = ['cifs', 'nfs', 'dir'].find((type) => types.includes(type));
    let later = anchor ? types.slice(types.indexOf(anchor) + 1) : [];
    let moved = later.map((type) => [type, schema[type]]);
    later.forEach((type) => delete schema[type]);

    schema.cetrafs = entry;
    moved.forEach(([type, value]) => {
        schema[type] = value;
    });
})();
