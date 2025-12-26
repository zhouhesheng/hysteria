//go:build !windows

package tun

import "syscall"

func dup(fd int) (nfd int, err error) {
	return syscall.Dup(fd)
}
