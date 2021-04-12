Really really really quick and extra dirty:

git clone openwrt (probably using openwrt-21.02 branch)
symlink dotconfig to .config in the openwrt dir
symlink files to files in the openwrt dir
make
modify docker-build.sh to point to your generated tarball
run docker-build.sh
