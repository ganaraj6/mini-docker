#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <sched.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <string.h>

/* Child clone() stack. Stacks grow downward on x86-64, so clone() is
 * given the top of this buffer (child_stack + STACK_SIZE). */
#define STACK_SIZE (1024 * 1024)
static char child_stack[STACK_SIZE];

struct container_config {
    char *hostname;
    char *rootfs;
    char *command;
};

/* Build "<rootfs>/proc" into buf. Returns 0 on success, -1 if too long. */
static int make_proc_path(char *buf, size_t buflen, const char *rootfs)
{
    int n = snprintf(buf, buflen, "%s/proc", rootfs);
    if (n < 0 || (size_t)n >= buflen) {
        return -1;
    }
    return 0;
}

/* Runs inside the new PID, UTS, and mount namespaces. */
int container_child(void *arg)
{
    struct container_config *config = (struct container_config *)arg;
    char proc_path[4096];

    /* sethostname: set the UTS namespace hostname for this container. */
    if (sethostname(config->hostname, strlen(config->hostname)) != 0) {
        perror("sethostname");
        return 1;
    }

    /* mount(..., MS_REC | MS_PRIVATE): stop mount events leaking to/from
     * the host. Makes this namespace's mounts private and recursive. */
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
        perror("mount MS_PRIVATE");
        return 1;
    }

    if (make_proc_path(proc_path, sizeof(proc_path), config->rootfs) != 0) {
        fprintf(stderr, "rootfs path too long\n");
        return 1;
    }

    /* Ensure the proc mount point exists inside the prepared rootfs. */
    if (mkdir(proc_path, 0555) != 0) {
        /* EEXIST is fine if setup_rootfs.sh already created it. */
    }

    /* mount("proc", ...): provide a container-local /proc so tools like
     * ps see only processes in this PID namespace. */
    if (mount("proc", proc_path, "proc", 0, NULL) != 0) {
        perror("mount proc");
        return 1;
    }

    /* chroot: confine the process to config->rootfs as its new "/". */
    if (chroot(config->rootfs) != 0) {
        perror("chroot");
        return 1;
    }

    /* chdir("/"): move cwd into the new root so relative paths work. */
    if (chdir("/") != 0) {
        perror("chdir");
        return 1;
    }

    /* execvp: replace this process with bash -c <user command>.
     * The binary lives at /bin/bash inside the chroot. */
    {
        char *args[] = { "/bin/bash", "-c", config->command, NULL };
        execvp("/bin/bash", args);
        perror("execvp");
        return 1;
    }
}

int main(int argc, char *argv[])
{
    struct container_config config;
    char proc_path[4096];
    pid_t child_pid;
    int flags;
    int status;

    if (argc != 4) {
        fprintf(stderr, "Usage: %s <hostname> <rootfs_path> <command>\n", argv[0]);
        return 1;
    }

    config.hostname = argv[1];
    config.rootfs = argv[2];
    config.command = argv[3];

    if (make_proc_path(proc_path, sizeof(proc_path), config.rootfs) != 0) {
        fprintf(stderr, "rootfs path too long\n");
        return 1;
    }

    /* CLONE_NEWPID: isolated process tree (child is PID 1 inside).
     * CLONE_NEWUTS: private hostname/domainname.
     * CLONE_NEWNS:  private mount namespace.
     * SIGCHLD:      deliver SIGCHLD to the parent when the child exits. */
    flags = CLONE_NEWPID | CLONE_NEWUTS | CLONE_NEWNS | SIGCHLD;

    /* clone: create the container process with the flags above.
     * child_stack + STACK_SIZE is the initial stack pointer. */
    child_pid = clone(container_child, child_stack + STACK_SIZE, flags, &config);
    if (child_pid < 0) {
        perror("clone");
        return 1;
    }

    /* waitpid: block until the container process exits. */
    if (waitpid(child_pid, &status, 0) < 0) {
        perror("waitpid");
        return 1;
    }

    /* umount: tear down the proc mount on the host-visible rootfs path.
     * With CLONE_NEWNS this may be a no-op if the mount lived only in
     * the child's namespace (which is destroyed when the child exits). */
    if (umount(proc_path) != 0) {
        /* Ignore failure: mount may already be gone with the child ns. */
    }

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return 1;
}
