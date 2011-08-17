. inc/common.sh

init

backup_dir=$topdir/xb_export_backup
rm -rf $backup_dir
mkdir $backup_dir

if [ -z "$XTRADB_VERSION" ]; then
    echo "Requires XtraDB" > $SKIPPED_REASON
    exit $SKIPPED_EXIT_CODE
fi

if [ ${MYSQL_VERSION:0:3} = "5.5" ]
then
    import_option="--innodb_import_table_from_xtrabackup=1"
else
    import_option="--innodb_expand_import=1"
fi

MYSQLD_ARGS="$MYSQLD_ARGS --innodb_file_per_table $import_option \
--innodb_file_format=Barracuda"

# Starting database server
run_mysqld

# Loading table schema
load_dbase_schema incremental_sample

# Adding some data to database
vlog "Adding initial rows to database..."
numrow=100
count=0
while [ "$numrow" -gt "$count" ]
do
	${MYSQL} ${MYSQL_ARGS} -e "insert into test values ($count, $numrow);" incremental_sample
	let "count=count+1"
done
vlog "Initial rows added"

checksum_1=`${MYSQL} ${MYSQL_ARGS} -Ns -e "checksum table test" incremental_sample | awk '{print $2}'`
rowsnum_1=`${MYSQL} ${MYSQL_ARGS} -Ns -e "select count(*) from test" incremental_sample`
vlog "rowsnum_1 is $rowsnum_1"
vlog "checksum_1 is $checksum_1"

# Performing table backup
xtrabackup --datadir=$mysql_datadir --backup --target-dir=$backup_dir
vlog "Table was backed up"

vlog "Re-initializing database server"
stop_mysqld
# Can't use clean/init because that will remove $backup_dir as well
clean_datadir
run_mysqld
load_dbase_schema incremental_sample
vlog "Database was re-initialized"

run_cmd ${MYSQL} ${MYSQL_ARGS} -e "alter table test discard tablespace;" incremental_sample

# Test the with innodb_file_per_table=0 --export bails out with an error
# (bug #758888)

run_cmd_expect_failure $XB_BIN $XB_ARGS --datadir=$mysql_datadir --prepare \
    --export --target-dir=$backup_dir --innodb-file-per-table=0

XB_ARGS="$XB_ARGS --innodb-file-per-table=1"

xtrabackup --datadir=$mysql_datadir --prepare --export \
    --target-dir=$backup_dir

run_cmd cp $backup_dir/incremental_sample/test* $mysql_datadir/incremental_sample/
run_cmd ls -lah $mysql_datadir/incremental_sample/
run_cmd ${MYSQL} ${MYSQL_ARGS} -e "alter table test import tablespace" incremental_sample
vlog "Table has been imported"

vlog "Cheking checksums"
checksum_2=`${MYSQL} ${MYSQL_ARGS} -Ns -e "checksum table test;" incremental_sample | awk '{print $2}'`
vlog "checksum_2 is $checksum_2"
rowsnum_1=`${MYSQL} ${MYSQL_ARGS} -Ns -e "select count(*) from test" incremental_sample`
vlog "rowsnum_1 is $rowsnum_1"

if [ "$checksum_1" != "$checksum_2"  ]
then 
	vlog "Checksums are not equal"
	exit -1
fi

vlog "Checksums are OK"

# Tablespace import is asynchronous, so shutdown the server to have
# consistent backup results. Otherwise we risk ending up with no test.ibd
# in the backup in case importing has not finished before taking backup

stop_mysqld
run_mysqld

# Some testing queries
run_cmd ${MYSQL} ${MYSQL_ARGS} -e "select count(*) from test;" incremental_sample
run_cmd ${MYSQL} ${MYSQL_ARGS} -e "show create table test;" incremental_sample

# Performing full backup of imported table
mkdir -p $topdir/backup/full

xtrabackup --datadir=$mysql_datadir --backup --target-dir=$topdir/backup/full

xtrabackup --datadir=$mysql_datadir --prepare --apply-log-only \
    --target-dir=$topdir/backup/full

xtrabackup --datadir=$mysql_datadir --prepare \
    --target-dir=$topdir/backup/full

run_cmd ${MYSQL} ${MYSQL_ARGS} -e "delete from test;" incremental_sample

stop_mysqld

cd $topdir/backup/full
cp -r * $mysql_datadir
cd -

run_mysqld

vlog "Cheking checksums"
checksum_3=`${MYSQL} ${MYSQL_ARGS} -Ns -e "checksum table test;" incremental_sample | awk '{print $2}'`
vlog "checksum_3 is $checksum_3"

if [ "$checksum_3" != $checksum_2  ]
then
        vlog "Checksums are not equal"
        exit -1
fi

vlog "Checksums are OK"

stop_mysqld

rm -rf $backup_dir