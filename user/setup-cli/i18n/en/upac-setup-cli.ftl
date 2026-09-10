error = Error

err-common = Common subsystem failure
err-mount = Mount failed
err-repo = Repository operation failed
err-database = Database operation failed
err-deploy-record = Deploy record operation failed
err-boot = Boot entry staging failed
err-boot-plugin = Boot plugin operation failed
err-io = I/O error
err-no-space-left = No space left on device
err-not-block-device = Not a block device
err-mkfs-failed = Filesystem creation failed
err-wipe-failed = Failed to wipe the target partition's existing filesystem signature
err-partition-not-ready = Partition device did not appear in time after partitioning
err-unexpected = Unexpected error

err-missing-device = Missing required argument: --device
err-missing-deploy-size = Missing required argument: --deploy-size
err-missing-source = Missing required argument: --source
err-invalid-partition-layout = Requested partition sizes don't fit on the disk
err-invalid-format-params = Invalid filesystem formatting parameters
err-reread-failed = Failed to reread the partition table (device busy?)
err-composefs-setup-root-unit-not-found = composefs-setup-root.service not found under source's system/ directory

stage-prepare-source = Preparing source
stage-enumerate-packages = Enumerating packages
stage-unpack-package = Unpacking package
stage-import-package = Importing package
stage-import-system = Importing system files
stage-embed-database = Embedding package database
stage-write-deploy-record = Writing deploy record
stage-stage-boot = Staging boot entry
stage-setup = Setup
