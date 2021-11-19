## Dockerfile

<pre>
<code>

FROM        centos:7

ENV         CUBRID_VERSION 11.0.4
ENV         CUBRID_BUILD_VERSION 11.0.4.0297-42780a3
ENV         USER cubrid

RUN         chmod -R 777 /tmp
RUN         yum install -y sudo procps wget glibc ncurses libgcrypt libstdc++
RUN         useradd -ms /bin/bash $USER
RUN         usermod -aG wheel $USER
RUN         echo '%wheel ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
RUN         su - $USER
RUN         wget -P /home/$USER http://ftp.cubrid.org/CUBRID_Engine/$CUBRID_VERSION/CUBRID-$CUBRID_BUILD_VERSION-Linux.x86_64.tar.gz
RUN         tar -zxf /home/$USER/CUBRID-$CUBRID_BUILD_VERSION-Linux.x86_64.tar.gz -C /home/$USER
RUN         mkdir -p /home/$USER/CUBRID/databases /home/$USER/CUBRID/var/CUBRID_SOCK
RUN         chmod -R 755 /home/$USER/CUBRID
RUN         chown -R $USER /home/$USER/CUBRID

COPY        run.sh /home/$USER
RUN         sudo chmod 755 /home/$USER/run.sh

EXPOSE      1523 8001 30000 33000

ENTRYPOINT  su - $USER

</code>
</pre>

## Makefile

<pre>
<code>

CONTAINER_NAME=cubrid
IMAGE_NAME=cubrid
VERSION=0.0.0

.PHONY 	:	build
build		:
					docker build --platform=linux/x86_64 --rm -t $(IMAGE_NAME):$(VERSION) .

.PHONY	:	run
run	:
	docker container run -i -t --name $(CONTAINER_NAME) --platform=linux/x86_64 -v /Users/saoh/42-course/cubrid/Backup_Data:/home/cubrid/CUBRID/Backup_Data -p 1523:1523 -p 8001:8001 -p 30000:30000 -p 33000:33000 $(IMAGE_NAME):$(VERSION)

.PHONY	:	start
start			: build run

.PHONY	:	clean
clean			:
					docker container rm -f $(CONTAINER_NAME)

.PHONY	:	img_clean
img_clean		:
					docker image rm -f $(IMAGE_NAME):$(VERSION)

.PHONY	:	fclean
fclean	:	clean img_clean

.PHONY	: re
re			:	fclean run

.PHONY	:	prune
prune		:
					docker image prune

.PHONY	: attach
attach	:
					docker container attach $(CONTAINER_NAME)

</code>
</pre>

## run.sh

<pre>
<code>

#!/bin/bash

USER=cubrid

echo 'export CUBRID=/home/$USER/CUBRID' >> /home/$USER/.bash_rc
echo 'export CUBRID_DATABASES=$CUBRID/databases' >> /home/$USER/.bash_rc
echo 'export CLASSPATH=$CUBRID/jdbc/cubrid_jdbc.jar' >> /home/$USER/.bash_rc
echo 'export LD_LIBRARY_PATH=$CUBRID/lib' >> /home/$USER/.bash_rc
echo 'export PATH=$CUBRID/bin:$PATH' >> /home/$USER/.bash_rc

source /home/$USER/.bash_rc

cd $CUBRID_DATABASES
mkdir demodb
cd demodb
cubrid createdb --db-volume-size=20M --log-volume-size=20M demodb ko_KR.utf8
cd

cubrid service start
cubrid loaddb -u dba -s $CUBRID/demo/demodb_schema -d $CUBRID/demo/demodb_objects demodb > /dev/null

</code>
</pre>

## practice code

<pre>
<code>

----------------------- practice 1 ------------------------------------
. run.sh
cd CUBRID/databases/
cubrid server start demodb
csql -u dba demodb
SHOW TABLES;
CREATE TABLE s1h (a INT PRIMARY KEY);
CREATE TABLE s1k (a INT PRIMARY KEY);
INSERT INTO s1h SELECT ROWNUM FROM db_class c1, db_class c2 LIMIT 100;
INSERT INTO s1k SELECT ROWNUM FROM db_class c1, db_class c2 LIMIT 1000;
SHOW TABLES;
SELECT * FROM s1h;
SELECT * FROM s1k;
CREATE TABLE t1 (a INT PRIMARY KEY, b INT, c INT, d CHAR(10),e CHAR(100),f CHAR(500),INDEX i_t1_b(b)) ;
INSERT INTO t1 SELECT ROWNUM, ROWNUM, ROWNUM, ROWNUM||'', ROWNUM||'', ROWNUM||'' FROM s1h,s1k;
SELECT * FROM t1 LIMIT 100;
cubrid backupdb -C -l 0 -D . demodb
ls -l
cp demodb_bk0v000 ../../Backup_Data/
cp demodb_bkvinf ../../Backup_Data/
cp demodb_lgat ../../Backup_Data/
csql -u dba demodb
CREATE TABLE t2 (a INT PRIMARY KEY, b INT, c INT, d CHAR(10),e CHAR(100),f CHAR(500),INDEX i_t1_b(b)) ;
CREATE TABLE t3 (a INT PRIMARY KEY, b INT, c INT, d CHAR(10),e CHAR(100),f CHAR(500),INDEX i_t1_b(b)) ;
INSERT INTO t2 SELECT ROWNUM, ROWNUM, ROWNUM, ROWNUM||'', ROWNUM||'', ROWNUM||'' FROM s1h,s1k;
INSERT INTO t3 SELECT ROWNUM, ROWNUM, ROWNUM, ROWNUM||'', ROWNUM||'', ROWNUM||'' FROM s1h,s1k;
SHOW TABLES;
SELECT * FROM t2 LIMIT 100;
SELECT * FROM t3 LIMIT 100;
cubrid server stop demodb
cubrid server status
cat demodb_lginf
cubrid restoredb -u -d  demodb
cubrid server start demodb
csql -u dba demodb
SHOW TABLES;
SELECT * FROM t1 LIMIT 100;
----------------------- practice 2 ------------------------------------
. run.sh
cd CUBRID/databases/demodb
cubrid server start demodb
csql -u dba demodb
SHOW TABLES;
cp ../../Backup_Data/demodb_bk0v000 ./
cp ../../Backup_Data/demodb_bkvinf ./
mv ../../Backup_Data/demodb_lgat ./
cubrid server stop demodb
cubrid restoredb -u -p demodb
cubrid server start demodb
csql -u dba demodb
SHOW TABLES;
SELECT * FROM s1h;
SELECT * FROM s1k;
SELECT * FROM t1 LIMIT 100;
----------------------- practice 3 ------------------------------------
cubrid unloaddb demodb
cd ..
mkdir demondb
cd demondb
cubrid createdb --db-volume-size=20M --log-volume-size=20M demondb ko_KR.utf8
cubrid server start demondb
csql -u dba demondb
SHOW TABLES;
mv ../demodb/demodb_schema ./
mv ../demodb/demodb_indexes ./
mv ../demodb/demodb_objects ./
cubrid server stop demondb
cubrid loaddb -u dba -i demodb_indexes -s demodb_schema -d demodb_objects demondb
cubrid server start demondb
csql -u dba demondb
SHOW TABLES;
SELECT * FROM s1h;
SELECT * FROM s1k;
SELECT * FROM t1 LIMIT 100;

</code>
</pre>
