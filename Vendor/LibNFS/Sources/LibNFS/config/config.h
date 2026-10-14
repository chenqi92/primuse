/*
 * libnfs 的 config.h,对应 cmake/ConfigureChecks.cmake 在 Apple 平台
 * (iOS、macOS、tvOS 及模拟器)上的检测结果。Linux 那一段只用于在开发机上
 * 编译、测试这个包,不进 App。
 */
#ifndef PRIMUSE_LIBNFS_CONFIG_H
#define PRIMUSE_LIBNFS_CONFIG_H

#define HAVE_ARPA_INET_H 1
#define HAVE_DLFCN_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_MEMORY_H 1
#define HAVE_NETDB_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_NETINET_TCP_H 1
#define HAVE_NET_IF_H 1
#define HAVE_POLL_H 1
#define HAVE_PTHREAD 1
#define HAVE_PWD_H 1
#define HAVE_SIGNAL_H 1
#define HAVE_SOCKADDR_STORAGE 1
#define HAVE_STDATOMIC_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_STATVFS_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_UIO_H 1
#define HAVE_SYS_UTSNAME_H 1
#define HAVE_UNISTD_H 1
#define HAVE_UTIME_H 1

#if defined(__APPLE__)
/* BSD sockets carry sa_len; ioctl FIONREAD lives in sys/filio.h. */
#define HAVE_SOCKADDR_LEN 1
#define HAVE_SYS_FILIO_H 1
#define HAVE_SYS_SOCKIO_H 1
#define HAVE_DISPATCH_DISPATCH_H 1
#define HAVE_PTHREAD_THREADID_NP 1
/* Darwin has no CLOCK_MONOTONIC_COARSE, st_mtim, sys/vfs.h or sysmacros.h. */
#ifndef _DARWIN_USE_64_BIT_INODE
#define _DARWIN_USE_64_BIT_INODE 1
#endif
#elif defined(__linux__)
#define HAVE_CLOCK_GETTIME 1
#define HAVE_SO_BINDTODEVICE 1
#define HAVE_STRUCT_STAT_ST_MTIM_TV_NSEC 1
#define HAVE_SYS_EVENTFD_H 1
#define HAVE_SYS_SYSMACROS_H 1
#define HAVE_SYS_VFS_H 1
#define MAJOR_IN_SYSMACROS 1
#else
#error "Unsupported platform for the vendored libnfs configuration"
#endif

#endif /* PRIMUSE_LIBNFS_CONFIG_H */
