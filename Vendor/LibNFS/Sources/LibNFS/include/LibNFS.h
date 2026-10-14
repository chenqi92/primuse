// Swift 用到的 libnfs 接口:同步 API(libnfs.h)、导出列表的 exportnode
// (MOUNT 协议)、NF3DIR 等文件类型常量(NFSv3 协议)与 NFS_V4(NFSv4 协议)。
#ifndef PRIMUSE_LIBNFS_H
#define PRIMUSE_LIBNFS_H

#include <nfsc/libnfs.h>
#include "../mount/libnfs-raw-mount.h"
#include "../nfs/libnfs-raw-nfs.h"
#include "../nfs4/libnfs-raw-nfs4.h"

#endif
