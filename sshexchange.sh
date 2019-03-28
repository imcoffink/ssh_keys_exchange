#! /bin/bash

### Usage
Usage()
{
	echo ""
	echo "Usage:"
	echo "$0 <config_file>"
	echo ""
	echo "Example:"
	echo "$0 sshexchange.conf"
	echo ""
	exit 1
}

### Parameter validation
if [ $# -lt 1 ]
then
	Usage
fi

### Set variables
CF_FILE=sshexchange.conf
if [ -f ${CF_FILE} ]
then
	echo "Missing configuration file!"
	exit 1
fi
. ${CF_FILE}

### Check if sshpass and python are installed
CheckSsshpassPython()
{
	SSHPASS=`sshpass > /dev/null 2>&1; echo $?`
	PYTHON=`ls -la /usr/bin |grep -i python >/dev/null 2>&1; echo $?`

	if [ ${SSHPASS} -ne 0 ]
	then
		echo "Missing sshpass package! Please install it and retry..."
		exit 1
	fi
	if [ ${PYTHON} -ne 0 ]
	then
		echo "Missing python package! Please install it and retry..."
		exit 1
	fi
}

### Remove gateway public key from known_hosts
RemoveKnownGwHost()
{
	sed -i "/${GW_HOST}/d" ~/.ssh/known_hosts
}

### Gateway host setup
SetupGateway()
{
	### Fetch current root ssh config and set new value
	CUR_ROOT_LOGIN=`sshpass -p ${GW_PASS} ssh -qo StrictHostKeyChecking=no ${GW_USER}@${GW_HOST} <<EOF
sudo -s cat /etc/ssh/sshd_config |grep PermitRootLogin |grep -v set
EOF`
	NEW_ROOT_LOGIN='PermitRootLogin yes'

	### Fetch current auth file ssh config and set new value
	CUR_AUTH_F=`sshpass -p ${GW_PASS} ssh -qo StrictHostKeyChecking=no ${GW_USER}@${GW_HOST} <<EOF
sudo -s cat /etc/ssh/sshd_config |egrep '^AuthorizedKeysFile|^#AuthorizedKeysFile'
EOF`
	CUR_AUTHFILE=$(echo "${CUR_AUTH_F}" | sed 's/\//\\\//g')
	NEW_AUTHFILE='AuthorizedKeysFile     .ssh\/authorized_keys'

	echo "
CUR_ROOT_LOGIN = ${CUR_ROOT_LOGIN}
NEW_ROOT_LOGIN = ${NEW_ROOT_LOGIN}
CUR_AUTH_F = ${CUR_AUTH_F}
CUR_AUTHFILE = ${CUR_AUTHFILE}
NEW_AUTHFILE = ${NEW_AUTHFILE}
"

	### If auth file variable is not empty:
	if [ ! -z "${CUR_AUTHFILE}" ]
	then

		### Update root ssh config, auth file ssh config and tty requirement
		sshpass -p ${GW_PASS} ssh -qo StrictHostKeyChecking=no ${GW_USER}@${GW_HOST} << EOF
sudo -s
sed -i "s/${CUR_ROOT_LOGIN}/${NEW_ROOT_LOGIN}/g" /etc/ssh/sshd_config
sed -i "s/${CUR_AUTHFILE}/${NEW_AUTHFILE}/g" /etc/ssh/sshd_config
sed -i \"s/^MACs/#&/\" /etc/ssh/sshd_config
chmod 755 /etc/sudoers
sed -i 's/^Defaults    requiretty/Defaults    !requiretty/g' /etc/sudoers
chmod 440 /etc/sudoers
EOF
	else

		### Update root ssh config and tty requirement
		sshpass -p ${GW_PASS} ssh -qo StrictHostKeyChecking=no ${GW_USER}@${GW_HOST} << EOF
sudo -s
sed -i "s/${CUR_ROOT_LOGIN}/${NEW_ROOT_LOGIN}/g" /etc/ssh/sshd_config
sed -i \"s/^MACs/#&/\" /etc/ssh/sshd_config
chmod 755 /etc/sudoers
sed -i 's/^Defaults    requiretty/Defaults    !requiretty/g' /etc/sudoers
chmod 440 /etc/sudoers
EOF
	fi
}

### Install expect on localhost
InstallLocalExpect()
{
	tar -xzf ${EXPECTF}
	cd ${EXPECTD}
	/usr/bin/python ./setup.py install
	cd -
}

### Change gateway password
ChangeGwPassXpc()
{
	### Validate gateway user
	if [ "${GW_USER}" = "root" ]
	then

	### Generate expect file for root to change password
	echo "#! /usr/bin/expect

set GWUSR [lindex \$argv 0];
set GWPWD [lindex \$argv 1];
set GWHST [lindex \$argv 2];

spawn sshpass -p \${GWPWD} ssh -qo StrictHostKeyChecking=no \${GWUSR}@\${GWHST} passwd
expect \"New password:\"
send \"\${GWPWD}\n\"
expect \"Retype new password:\"
send \"\${GWPWD}\n\"
expect eof" > ${CHPWDFL}

	### Grant execution permission on expect file
	chmod +x ${CHPWDFL}

	### Change root password on gateway host
	echo "
CHPWDFL = ${CHPWDFL}
GW_USER = ${GW_USER}
GW_PASS = ${GW_PASS}
GW_HOST = ${GW_HOST}
"
	expect -f ${CHPWDFL} ${GW_USER} ${GW_PASS} ${GW_HOST}

	### Remove expect file
	rm -rf ${CHPWDFL}

	else

	### Generate expect file for non-root user to change root password
	echo "#! /usr/bin/expect

set GWUSR [lindex \$argv 0];
set GWPWD [lindex \$argv 1];
set GWHST [lindex \$argv 2];

spawn sshpass -p \${GWPWD} ssh -qo StrictHostKeyChecking=no \${GWUSR}@\${GWHST} sudo -s passwd
expect \"New password:\"
send \"\${GWPWD}\n\"
expect \"Retype new password:\"
send \"\${GWPWD}\n\"
expect eof" > ${CHPWDFL}

	### Grant execution permission on expect file
	chmod +x ${CHPWDFL}

	### Change root password on gateway host
	expect -f ${CHPWDFL} ${GW_USER} ${GW_PASS} ${GW_HOST}

	### Remove expect file
	rm -rf ${CHPWDFL}

	fi
}

### Restart SSH service on gateway host
RestartGwSshd()
{
	sshpass -p ${GW_PASS} ssh -qo StrictHostKeyChecking=no ${GW_USER}@${GW_HOST} <<EOF
sudo -s
. ~/.bash_profile
service sshd restart
EOF

	### Redefine GW_USER to root now that root login is enabled
	export GW_USER=root
}

### Generate remote script
GenerateRemoteScript()
{
	echo "#! /bin/bash -x

### Define variables
export LC_HOST=\$1
shift
export LC_USER=\$1
shift
export LC_PASS=\$1
shift
export RT_HOSTS=\$1
shift
export RT_USERS=\$1
shift
export RT_PASS=\$1
shift
export CHPWDFL=\$1
shift
export EXPECTD=\$1
shift
export EXPECTF=\$1
shift
export SSHXCHD=\$1

### Format hosts and users into usable lists
export SSHXCHD=~/\${SSHXCHD}
export RT_HOSTS=\`echo \${RT_HOSTS} |tr ';' ' '\`
export RT_USERS=\`echo \${RT_USERS} |tr ';' ' '\`

### Debug variables
echo \"

Debug variables

LC_HOST  = \${LC_HOST}
LC_USER  = \${LC_USER}
LC_PASS  = \${LC_PASS}
RT_HOSTS = \${RT_HOSTS}
RT_USERS = \${RT_USERS}
RT_PASS  = \${RT_PASS}
CHPWDFL  = \${CHPWDFL}
EXPECTD  = \${EXPECTD}
EXPECTF  = \${EXPECTF}
SSHXCHD  = \${SSHXCHD}
\"

### Install expect on gateway host
InstallGwExpect()
{
	cd \${SSHXCHD}
	tar -xzf \${EXPECTF}
	cd \${EXPECTD}
	/usr/bin/python ./setup.py install
	cd -
}

### Check if gateway server already have a public key, if not, generate one
CheckOrGenerateGwPubKey()
{
	KEYGENX=keygenx.expect

	if [ ! -f ~/.ssh/id_rsa.pub ]
	then
		### Generate expect file for ssh key generation
		echo \"#! /usr/bin/expect
spawn ssh-keygen -t rsa
expect 'Generating public/private rsa key pair.\nEnter file in which to save the key (/home/admin/.ssh/id_rsa):'
send '\n'
expect 'Enter passphrase (empty for no passphrase):'´
send '\n'
expect 'Enter same passphrase again:'
send '\n'
expect eof\" > \${KEYGENX}

		### Generate key
		expect -f \${KEYGENX}

		### Remove expect file
		rm -rf \${KEYGENX}
	fi
}

### Remove runtime machines from known_hosts
RemoveRtFromKnownHosts()
{
	for h in \${RT_HOSTS}
	do
		sed -i \"/\${h}/d\" ~/.ssh/known_hosts
	done
}

### Setup runtime machines
SetupRtHosts()
{
	for h in \${RT_HOSTS}
	do
		for u in \${RT_USERS}
		do
			if [ \"\${u}\" = \"root\" ]
			then
				### Fetch current root ssh config and set new value
				CUR_ROOT_LOGIN=\`sshpass -p \${RT_PASS} ssh -qo StrictHostKeyChecking=no \${u}@\${h} <<EOF
cat /etc/ssh/sshd_config |grep PermitRootLogin |grep -v set
EOF
\`
				NEW_ROOT_LOGIN='PermitRootLogin yes'
				CUR_AUTHFILE=\`sshpass -p \${RT_PASS} ssh -qo StrictHostKeyChecking=no \${u}@\${h} <<EOF
cat /etc/ssh/sshd_config |egrep '^AuthorizedKeysFile|^#AuthorizedKeysFile'
EOF
\`
				NEW_AUTHFILE='AuthorizedKeysFile     .ssh/authorized_keys'

				### Update root ssh config, auth file ssh config and tty requirement
				sshpass -p \${RT_PASS} ssh -qo StrictHostKeyChecking=no \${u}@\${h} << EOF
sed -i \"s;\${CUR_ROOT_LOGIN};\${NEW_ROOT_LOGIN};g\" /etc/ssh/sshd_config
sed -i \"s;\${CUR_AUTHFILE};\${NEW_AUTHFILE};g\" /etc/ssh/sshd_config
sed -i \"s/^MACs/#&/\" /etc/ssh/sshd_config
chmod 755 /etc/sudoers
sed -i \'s/^Defaults    requiretty/Defaults    !requiretty/g\' /etc/sudoers
chmod 440 /etc/sudoers
EOF
			else
				### Fetch current root ssh config and set new value
				CUR_ROOT_LOGIN=\`sshpass -p \${RT_PASS} ssh -qo StrictHostKeyChecking=no \${u}@\${h} <<EOF
sudo -s cat /etc/ssh/sshd_config |grep PermitRootLogin |grep -v set
EOF
\`
				NEW_ROOT_LOGIN='PermitRootLogin yes'
				CUR_AUTHFILE=\`sshpass -p \${RT_PASS} ssh -qo StrictHostKeyChecking=no \${u}@\${h} <<EOF
sudo -s cat /etc/ssh/sshd_config |egrep '^AuthorizedKeysFile|^#AuthorizedKeysFile'
EOF
\`
				NEW_AUTHFILE='AuthorizedKeysFile     .ssh/authorized_keys'

				### Update root ssh config, auth file ssh config and tty requirement
				sshpass -p \${RT_PASS} ssh -qo StrictHostKeyChecking=no \${u}@\${h} << EOF
sudo -s
sed -i \"s;\${CUR_ROOT_LOGIN};\${NEW_ROOT_LOGIN};g\" /etc/ssh/sshd_config
sed -i \"s;\${CUR_AUTHFILE};\${NEW_AUTHFILE};g\" /etc/ssh/sshd_config
sed -i \"s/^MACs/#&/\" /etc/ssh/sshd_config
chmod 755 /etc/sudoers
sed -i \'s/^Defaults    requiretty/Defaults    !requiretty/g\' /etc/sudoers
chmod 440 /etc/sudoers
EOF
			fi
		done
	done
}

### Restart runtime machines ssh service
RestartRtSshd()
{
	for h in \${RT_HOSTS}
	do
		for u in \${RT_USERS}
		do
			sshpass -p \${RT_PASS} ssh -qo StrictHostKeyChecking=no \${u}@\${h} <<EOF
sudo -s
. ~/.bash_profile
service sshd restart
EOF
		done
	done
}

### Change runtime machines root password
ChangeRtPassXpc()
{
	for h in \${RT_HOSTS}
	do
		for u in \${RT_USERS}
		do
			### Validate runtime user
			if [ \"\${u}\" != \"root\" ]
			then

				### Generate expect file for root to change password
				echo '#! /usr/bin/expect

set GWUSR [lindex \$argv 0];
set GWPWD [lindex \$argv 1];
set GWHST [lindex \$argv 2];

spawn sshpass -p \${GWPWD} ssh -o StrictHostKeyChecking=no \${GWUSR}@\${GWHST} sudo -s passwd
expect \"New password:\"
send \"\${GWPWD}\n\"
expect \"Retype new password:\"
send \"\${GWPWD}\n\"
expect eof' > \${CHPWDFL}

				### Grant execution permission on expect file
				chmod +x \${CHPWDFL}

				### Change root password on gateway host
				expect -f \${CHPWDFL} \${u} \${RT_PASS} \${h}

				### Remove expect file
				rm -rf \${CHPWDFL}

			else

				### Generate expect file for non-root user to change root password
				echo '#! /usr/bin/expect

set GWUSR [lindex \$argv 0];
set GWPWD [lindex \$argv 1];
set GWHST [lindex \$argv 2];

spawn sshpass -p \${GWPWD} ssh -o StrictHostKeyChecking=no \${GWUSR}@\${GWHST} passwd
expect \"New password:\"
send \"\${GWPWD}\n\"
expect \"Retype new password:\"
send \"\${GWPWD}\n\"
expect eof' > \${CHPWDFL}

				### Grant execution permission on expect file
				chmod +x \${CHPWDFL}

				### Change root password on gateway host
				expect -f \${CHPWDFL} \${u} \${RT_PASS} \${h}

				### Remove expect file
				rm -rf \${CHPWDFL}
			fi
		done
	done
}

### Copy public key to runtime machines
SshKeyCopyToRtHosts()
{
	### Copy ssh key to runtime machines
	for h in \${RT_HOSTS}
	do
		for u in \${RT_USERS}
		do

			### Generate expect file
			echo '#!/usr/bin/expect

set RTHST [lindex \$argv 0];
set RTUSR [lindex \$argv 1];
set RTPWD [lindex \$argv 2];

spawn ssh-copy-id -i ~/.ssh/id_rsa.pub \${RTUSR}@\${RTHST}
expect \"\${RTUSR}@\${RTHST}%s password:\"
send \"\${RTPWD}\n\"
expect eof' > \${CHPWDFL}

			sed -i \"s/%s/'s/g\" \${CHPWDFL}

			if [ \"\${LC_USER}\" = \"root\" ]
			then
				sed -i 's/~\/.ssh/\/root\/.ssh/g' \${CHPWDFL}
			else
				sed -i \"s/~\/.ssh/\/home\/\${u}\/.ssh/g\" \${CHPWDFL}
			fi
			expect -f \${CHPWDFL} \${h} \${u} \${RT_PASS}

			### Remove expect file
		rm -rf \${CHPWDFL}

		done
	done
}

### Copy public key from runtime machines
SshKeyCopyFromRtHosts()
{
	KEYGENX=checkkeys.expect

	### Copy expect files to runtime machines
	for h in \${RT_HOSTS}
	do
		for u in \${RT_USERS}
		do

			### Generate keygen expect file
			echo '#! /usr/bin/expect

spawn ssh-keygen -t rsa
expect \"Generating public/private rsa key pair.\nEnter file in which to save the key (/home/admin/.ssh/id_rsa):\"
send \"\n\"
expect \"Enter passphrase (empty for no passphrase):\"
send \"\n\"
expect \"Enter same passphrase again:\"
send \"\n\"
expect eof' > \${KEYGENX}

			### Generate ssh-copy-id expect file
			echo '#! /usr/bin/expect

set GWHST [lindex \$argv 0];
set GWUSR [lindex \$argv 1];
set GWPWD [lindex \$argv 2];

spawn ssh-copy-id -i ~/.ssh/id_rsa.pub \${GWUSR}@\${GWHST}
expect \"The authenticity of host
RSA key fingerprint is SHA256:
RSA key fingerprint is MD5:
Are you sure you want to continue connecting (yes/no)?\"
send \"yes\n\"
expect \"/usr/bin/ssh-copy-id: INFO: Source of key(s) to be installed:
/usr/bin/ssh-copy-id: INFO: attempting to log in with the new key(s), to filter out any that are already installed
/usr/bin/ssh-copy-id: INFO: 1 key(s) remain to be installed -- if you are prompted now it is to install the new keys
\${GWUSR}@\${GWHST}%s password:\"
send \"\${GWPWD}\n\"
expect eof' > \${CHPWDFL}

			sed -i \"s/%s/\'s/g\" \${CHPWDFL}

			if [ \"\${u}\" = \"root\" ]
			then
				sed -i 's/~\/.ssh/\/root\/.ssh/g' \${CHPWDFL}
			else
				sed -i \"s/~\/.ssh/\/home\/\${u}\/.ssh/g\" \${CHPWDFL}
			fi
			sshpass -p \${RT_PASS} scp -q \${CHPWDFL} \${u}@\${h}:~/
			sshpass -p \${RT_PASS} scp -q \${KEYGENX} \${u}@\${h}:~/
		done
	done

	### Check if runtime machines already have ssh keys, if not, generate
	for h in \${RT_HOSTS}
	do
		for u in \${RT_USERS}
		do
			sshpass -p \${RT_PASS} ssh -qo StrictHostKeyChecking=no \${u}@\${h} <<EOF
. ~/.bash_profile > /dev/null 2>&1
if [ ! -f ~/.ssh/id_rsa.pub ]
then
	expect -f \${KEYGENX}
fi
rm -rf ${KEYGENX}
EOF
		done
	done

	### Copy public key from runtime machines
	for h in \${RT_HOSTS}
	do
		for u in \${RT_USERS}
		do
			sshpass -p \${RT_PASS} ssh -qo StrictHostKeyChecking=no \${u}@\${h} <<EOF
. ~/.bash_profile > /dev/null 2>&1
expect -f \${CHPWDFL} \${LC_HOST} \${LC_USER} \${LC_PASS}
rm -rf \${CHPWDFL}
EOF
		done
	done
	
	### Insert gateway server host id into runtime machines known_hosts
	LC_HOST_ID=\`cat ~/.ssh/known_hosts |grep \${LC_HOST}\`
	for h in \${RT_HOSTS}
	do
		for u in \${RT_USERS}
		do
			sshpass -p \${RT_PASS} ssh -qo StrictHostKeyChecking=no \${u}@\${h} <<EOF
. ~/.bash_profile > /dev/null 2>&1
if [ ! -f ~/.ssh/known_hosts ]
then
	touch ~/.ssh/known_hosts
	chmod 600 ~/.ssh/known_hosts
fi
if [ \`cat ~/.ssh/known_hosts |grep \${LC_HOST} |wc -l\` -gt 1 ]
then
	sed -i \"/\${LC_HOST}/d\" ~/.ssh/known_hosts
elif [ \`cat ~/.ssh/known_hosts |grep \${LC_HOST} |wc -l\` -eq 0 ]
then
	echo \"\${LC_HOST_ID}\" >> ~/.ssh/known_hosts
fi
EOF
		done
	done
}

### Disable gateway and runtime machines firewall
DisableFirewalls()
{
	systemctl stop firewalld
	systemctl disable firewalld
	service iptables stop
	
	for h in \${RT_HOSTS}
	do
		for u in \${RT_USERS}
		do
			if [ \"\${u}\" = \"root\" ]
			then
				sshpass -p \${RT_PASS} ssh -q -o StrictHostKeyChecking=no \${u}@\${h} <<EOF
. ~/.bash_profile >/dev/null 2>&1
systemctl stop firewalld
systemctl disable firewalld
service iptables stop
EOF
			else
				sshpass -p \${RT_PASS} ssh -q -o StrictHostKeyChecking=no \${u}@\${h} <<EOF
sudo -s
. ~/.bash_profile >/dev/null 2>&1
systemctl stop firewalld
systemctl disable firewalld
service iptables stop
EOF
			fi
		done
	done
}

### Clear Variables
UnsetVariables()
{
	unset LC_HOST
	unset LC_USER
	unset LC_PASS
	unset RT_HOSTS
	unset RT_USERS
	unset RT_PASS
	unset CHPWDFL
	unset EXPECTD
	unset EXPECTF
	unset SSHXCHD
}

### MAIN
InstallGwExpect
CheckOrGenerateGwPubKey
RemoveRtFromKnownHosts
SetupRtHosts
RestartRtSshd
ChangeRtPassXpc
SshKeyCopyToRtHosts
SshKeyCopyFromRtHosts
DisableFirewalls
UnsetVariables
" > ${RMTXCHF}

	### Grant execute permission to remote script
	chmod +x ${RMTXCHF}
}

### Pack files to send to gateway host
PackExchangeFiles()
{
	tar -czf ${SSHXCHF} ${RMTXCHF} ${EXPECTF}
}

### Send packed files to gateway host
SendExchangeFilesToGw()
{
	sshpass -p ${GW_PASS} scp -q ${SSHXCHF} ${GW_USER}@${GW_HOST}:~/
}

### Unpack and execute exchange files on gateway host
RunGwExchange()
{
	sshpass -p ${GW_PASS} ssh -qo StrictHostKeyChecking=no ${GW_USER}@${GW_HOST} <<EOF
. ~/.bash_profile >/dev/null 2>&1
cd ~/
mkdir -p ${SSHXCHD}
tar -xzf ${SSHXCHF} -C ./${SSHXCHD}/
cd ${SSHXCHD}
./${RMTXCHF} ${GW_HOST} ${GW_USER} ${GW_PASS} "${LS_HOSTS}" "${LS_USERS}" "${LS_PASS}" ${CHPWDFL} ${EXPECTD} ${EXPECTF} ${SSHXCHD}
cd ..
rm -rf ${SSHXCHD}
rm -rf ${SSHXCHF}
rm -rf ${RMTXCHF}
EOF
}

### Clean variables
UnsetVariables()
{
	unset GW_HOST
	unset GW_USER
	unset GW_PASS
	unset LS_HOSTS
	unset LS_USERS
	unset LS_PASS
	unset CHPWDFL
	unset EXPECTD
	unset EXPECTF
	unset SSHXCHD
	unset SSHXCHF
	unset RMTXCHF
}


### MAIN
CheckSsshpassPython
RemoveKnownGwHost
SetupGateway
InstallLocalExpect
ChangeGwPassXpc
RestartGwSshd
GenerateRemoteScript
PackExchangeFiles
SendExchangeFilesToGw
RunGwExchange
UnsetVariables
