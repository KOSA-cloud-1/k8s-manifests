# Backup And Restore

The `photo-backup` CronJob runs in the `backup` namespace and connects to:

- MariaDB Galera: `mysql.data.svc.cluster.local`
- Ceph RGW: `ceph-secret`
- AWS S3 backup bucket: `aws-secret`

Run an on-demand backup:

```bash
kubectl -n backup create job backup-now --from=cronjob/photo-backup
kubectl -n backup logs -f job/backup-now
```

Minimum restore drill:

1. Pick a non-production namespace or temporary database.
2. Restore one backup object from AWS S3.
3. Restore matching image/object data from Ceph RGW or backup storage.
4. Verify `employee.object_key`, `storage_type`, and `backup_status`.
5. Document elapsed time and any manual steps.

Do this before relying on the CronJob as an operational backup.
