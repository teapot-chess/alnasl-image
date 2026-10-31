/*
 * alnasl-fbtool: the two ioctls the boot screen painter needs and Elixir cannot make.
 *
 *   alnasl-fbtool vinfo /dev/fb0       FBIOGET_VSCREENINFO, the fields the painter uses, as key=value lines:
 *                                      xres yres yoffset bits_per_pixel
 *                                      red_offset red_length green_offset green_length blue_offset blue_length
 *   alnasl-fbtool graphics /dev/tty1   KDSETMODE KD_GRAPHICS: the console stops drawing over the picture
 *
 * Exit 0 on success; 1 when the device or the ioctl fails (the message goes to stderr); 2 on bad usage.
 * Built with gcc into the release's bin/ (setup-app/Dockerfile). Nothing else: no state, no files written.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/fb.h>
#include <linux/kd.h>

static int vinfo(const char *path)
{
	struct fb_var_screeninfo v;
	int fd = open(path, O_RDWR);

	if (fd < 0) {
		fprintf(stderr, "alnasl-fbtool: %s: %s\n", path, strerror(errno));
		return 1;
	}
	memset(&v, 0, sizeof(v));
	if (ioctl(fd, FBIOGET_VSCREENINFO, &v) < 0) {
		fprintf(stderr, "alnasl-fbtool: FBIOGET_VSCREENINFO: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	close(fd);
	printf("xres=%u\nyres=%u\nyoffset=%u\nbits_per_pixel=%u\n", v.xres, v.yres, v.yoffset, v.bits_per_pixel);
	printf("red_offset=%u\nred_length=%u\n", v.red.offset, v.red.length);
	printf("green_offset=%u\ngreen_length=%u\n", v.green.offset, v.green.length);
	printf("blue_offset=%u\nblue_length=%u\n", v.blue.offset, v.blue.length);
	return 0;
}

static int graphics(const char *path)
{
	int fd = open(path, O_RDWR | O_NOCTTY);

	if (fd < 0) {
		fprintf(stderr, "alnasl-fbtool: %s: %s\n", path, strerror(errno));
		return 1;
	}
	if (ioctl(fd, KDSETMODE, KD_GRAPHICS) < 0) {
		fprintf(stderr, "alnasl-fbtool: KDSETMODE: %s\n", strerror(errno));
		close(fd);
		return 1;
	}
	close(fd);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc == 3 && strcmp(argv[1], "vinfo") == 0)
		return vinfo(argv[2]);
	if (argc == 3 && strcmp(argv[1], "graphics") == 0)
		return graphics(argv[2]);
	fprintf(stderr, "usage: alnasl-fbtool vinfo /dev/fb0 | graphics /dev/tty1\n");
	return 2;
}
