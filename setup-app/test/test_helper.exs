# :unix tests need a POSIX box (symlinks, /bin/sh, real commands): the build container and the box itself
# run them; a Windows PC skips them.
exclude = if match?({:win32, _}, :os.type()), do: [:unix], else: []
ExUnit.start(exclude: exclude)
