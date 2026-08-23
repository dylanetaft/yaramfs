#!/bin/sh
## An example, you could launch a script local to a filesystem on the booting system
pdev=$(findfs UUID="99999999-9999-9999-9999-999999999999")
mount "${pdev}" /mnt/provisioned
/mnt/provisioned/yaramfs/custom.sh
umount /mnt/provisioned
