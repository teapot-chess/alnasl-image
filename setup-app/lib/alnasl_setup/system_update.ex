defmodule AlnaslSetup.SystemUpdate do
  @moduledoc """
  alnasl-system-update: whole-system updates without reflashing (v6, A/B slots).

      alnasl-system-update --check            ask the release index what there is; change nothing
      alnasl-system-update --nightly          from alnasl-os-update, inside 03:00-05:00 and only when no round
                                              is live: install the newest image OF THIS BOX'S TRAIN, restart
                                              into it (exit 3), or leave it staged when the window is over
      alnasl-system-update --request          what the menu, Arkab or the boot file asked for (the request
                                              file): "install" (this train, now) or "upgrade" to a named train
      alnasl-system-update --from-boot-file   /boot/efi/alnasl-upgrade.txt (one word: the train, e.g. v7)
      alnasl-system-update --boot-check       at every boot: is this a trial of a new slot, is it healthy,
                                              was there a rollback; marks the slot good or gives up on it
      alnasl-system-update --status           the status as JSON (the setup server's /api/system)

  The card: boot (FAT) | system A | system B | data. One system slot runs, the other takes the next image.
  grub picks the slot from /boot/efi/alnasl/grubenv: alnasl_slot (the good one), alnasl_try + alnasl_tries
  (a new slot on trial, 3 boots), alnasl_failed (set by grub when the trial ran out: it went back).

  Trains (the user's rule, never auto-update between them): a train is a major image line (v6). Inside a
  train (6.0 -> 6.1 -> 6.2) updates install by themselves at night. An image of another train is refused
  unless that exact train was asked for with "Upgrade to v7" (menu, Arkab, or alnasl-upgrade.txt).

  Trust: the index (index.json) and every image are signed; the signatures are checked with openssl against
  the public key baked into the image (/etc/alnasl/update-key.pub). A placeholder key switches updates off.

  This used to be a Python program; the files it reads and writes, its exit codes, its output and its log
  lines are the same. What Elixir has no call for is done with the box's own tools:

    * the locks (Python's fcntl.flock): util-linux `flock <lockfile> cat`, run as a port. flock opens the
      lock file and takes the lock, then runs cat with the port's pipe as its stdin; cat echoes a line
      back once it runs, which says the lock is held. It is held until the port closes (cat sees end of
      input and exits): on release, or when this program dies in any way. `-n` for the non-blocking ones
      (the command lock, the --status probe), without for the status file's own lock (blocking).
    * free space (shutil.disk_usage): `df --output=avail -B1`.
    * unpacking an image (a zstd/xz pipe read by Python): the decompressor writes into a FIFO this
      program reads 4 MiB at a time, so it never runs ahead of the card and no image is ever held in
      memory (a port's output would arrive as fast as zstd makes it, with nothing to hold it back).

  Seams for the tests (application environment `:system_update`, unset on the box): `:http`
  (`fn url, opts -> {:ok, status, body} | {:error, reason} end`, after redirects), `:lock`
  (`fn real_path, :nb | :block -> {:ok, release_fun} | :busy | {:error, why} end`), `:sleep`,
  `:monotonic` and `:root_part`.
  """

  import Bitwise
  require Record
  alias AlnaslSetup.{Json, Sys}

  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  # Python's __doc__, written to stderr on a wrong command line.
  @usage """
  alnasl-system-update: whole-system updates without reflashing (v6, A/B slots).

      alnasl-system-update --check            ask the release index what there is; change nothing
      alnasl-system-update --nightly          from alnasl-os-update, inside 03:00-05:00 and only when no round
                                              is live: install the newest image OF THIS BOX'S TRAIN, restart
                                              into it (exit 3), or leave it staged when the window is over
      alnasl-system-update --request          what the menu, Arkab or the boot file asked for (the request
                                              file): "install" (this train, now) or "upgrade" to a named train
      alnasl-system-update --from-boot-file   /boot/efi/alnasl-upgrade.txt (one word: the train, e.g. v7)
      alnasl-system-update --boot-check       at every boot: is this a trial of a new slot, is it healthy,
                                              was there a rollback; marks the slot good or gives up on it
      alnasl-system-update --status           the status as JSON (the setup server's /api/system)

  The card: boot (FAT) | system A | system B | data. One system slot runs, the other takes the next image.
  grub picks the slot from /boot/efi/alnasl/grubenv: alnasl_slot (the good one), alnasl_try + alnasl_tries
  (a new slot on trial, 3 boots), alnasl_failed (set by grub when the trial ran out: it went back).

  Trains (the user's rule, never auto-update between them): a train is a major image line (v6). Inside a
  train (6.0 -> 6.1 -> 6.2) updates install by themselves at night. An image of another train is refused
  unless that exact train was asked for with "Upgrade to v7" (menu, Arkab, or alnasl-upgrade.txt).

  Trust: the index (index.json) and every image are signed; the signatures are checked with openssl against
  the public key baked into the image (/etc/alnasl/update-key.pub). A placeholder key switches updates off.
  """

  @release_file "/etc/alnasl/image-release"
  @key "/etc/alnasl/update-key.pub"
  @update_conf "/etc/alnasl/update.conf"
  @setup_state "/var/lib/alnasl-setup/state.json"
  @mode_file "/var/lib/alnasl-setup/mode"
  # v7: what the box is (alnasl-mode); master/slave are v6's words for alnasl/arkab.
  @role_aliases %{"master" => "alnasl", "slave" => "arkab"}
  @role_app %{
    "alnasl" => {"Alnasl", 4040},
    "arkab" => {"Arkab", 4050},
    "polis" => {"Polis", 4061},
    "nunki" => {"Nunki", 4062}
  }
  @role_order ~w(alnasl arkab polis nunki)
  @os_dir "/var/lib/alnasl-os-update"
  @dir @os_dir <> "/system"
  @status @dir <> "/status.json"
  @request @dir <> "/request"
  @trial @dir <> "/trial.json"
  @dl @dir <> "/download"
  @last @os_dir <> "/system-last-result"
  @history @os_dir <> "/system-history"
  @grubenv "/boot/efi/alnasl/grubenv"
  @boot_file "/boot/efi/alnasl-upgrade.txt"
  @boot_efi "/boot/efi"
  @splash "/usr/local/sbin/alnasl-splash"
  @lock "/run/alnasl-system-update.lock"
  @status_lock "/run/alnasl-system-update.status.lock"
  @painted "/run/alnasl-kiosk/painted"
  @newslot "/run/alnasl-newslot"
  @default_index "https://github.com/teapot-chess/alnasl-image/releases/download/index/index.json"

  # the MBR disk identifier every v6+ image carries ("Alns")
  @disk_id "416c6e73"
  @partno %{"A" => 2, "B" => 3}
  @label %{"A" => "ALNASL_A", "B" => "ALNASL_B"}
  # boots a new slot gets before grub goes back
  @tries 3
  # a first boot after an update may load a new kiosk image
  @health_minutes 15
  # v7.1: ... and while it is still loading one, it gets this long
  @health_max_minutes 60
  # [03:00, 05:00): the only hours a nightly restart may happen
  @window {3, 5}
  @alnasl_status_url "http://127.0.0.1:4040/local/status"
  @env_head "# GRUB Environment Block\n"
  @max_image 4 <<< 30
  @ua [{"User-Agent", "alnasl-system-update"}]

  @doc false
  def tries, do: @tries
  @doc false
  def role_app, do: @role_app

  # The patterns. Python's re.match with "$" also matched before a final newline; these use \z (the end,
  # nothing after), which no real value notices and which keeps a newline out of every one of them.
  defp re(:safe), do: ~r/^[A-Za-z0-9._-]{0,64}\z/
  defp re(:train), do: ~r/^v([0-9]{1,3})\z/
  defp re(:version), do: ~r/^([0-9]{1,3})\.([0-9]{1,4})(?:\.([0-9]{1,4}))?\z/
  defp re(:sha), do: ~r/^[0-9a-f]{64}\z/
  defp re(:file), do: ~r/^[A-Za-z0-9._-]+\.(zst|xz)\z/
  defp re(:kv), do: ~r/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*"?([^"]*)"?\s*$/

  # ------------------------------------------------------------------- errors --
  # Refused: something this box will not do, with the sentence that says why. The others stand for the
  # Python exceptions the program caught by kind: ValueError, OSError, URLError (HTTPError among them).

  defp refuse(msg), do: throw({:sysupd, :refused, msg})
  defp value_error(type \\ "ValueError", msg), do: throw({:sysupd, :value, type, msg})
  defp os_error(type, msg), do: throw({:sysupd, :os, type, msg})
  defp url_error(type, msg), do: throw({:sysupd, :url, type, msg})

  # {:ok, value} | {:refused, msg} | {:err, kind, type, msg}; anything else goes on up (Python crashed too).
  defp catching(fun) do
    {:ok, fun.()}
  catch
    :throw, {:sysupd, :refused, m} -> {:refused, m}
    :throw, {:sysupd, k, t, m} -> {:err, k, t, m}
    :error, e when is_exception(e) and is_map_key(e, :reason) -> file_error(e)
  end

  defp file_error(%{reason: r} = e)
       when is_struct(e, File.Error) or is_struct(e, File.CopyError) or
              is_struct(e, File.RenameError) or is_struct(e, File.LinkError) do
    {n, text, type} = errno(r)

    where =
      case e do
        %File.Error{path: p} -> "'#{p}'"
        %File.CopyError{source: s, destination: d} -> "'#{s}' -> '#{d}'"
        %File.RenameError{source: s, destination: d} -> "'#{s}' -> '#{d}'"
        %File.LinkError{existing: s, new: d} -> "'#{s}' -> '#{d}'"
      end

    {:err, :os, type, "[Errno #{n}] #{text}: #{where}"}
  end

  defp file_error(e), do: raise(e)

  defp errno(:enoent), do: {2, "No such file or directory", "FileNotFoundError"}
  defp errno(:eacces), do: {13, "Permission denied", "PermissionError"}
  defp errno(:eperm), do: {1, "Operation not permitted", "PermissionError"}
  defp errno(:eexist), do: {17, "File exists", "FileExistsError"}
  defp errno(:eisdir), do: {21, "Is a directory", "IsADirectoryError"}
  defp errno(:enotdir), do: {20, "Not a directory", "NotADirectoryError"}
  defp errno(:enospc), do: {28, "No space left on device", "OSError"}
  defp errno(:erofs), do: {30, "Read-only file system", "OSError"}
  defp errno(:eio), do: {5, "Input/output error", "OSError"}
  defp errno(:ebusy), do: {16, "Device or resource busy", "OSError"}
  defp errno(r), do: {0, to_string(:file.format_error(r)), "OSError"}

  defp ferr!(reason, action, path), do: raise(File.Error, reason: reason, action: action, path: path)

  @doc """
  Runs `fun` and says how it ended, for the tests and the callers in-process: `{:ok, value}`,
  `{:refused, sentence}`, `{:value_error | :os_error | :url_error, "Type: message"}`, or `{:error, text}`.
  """
  def attempt(fun) do
    case catching(fun) do
      {:ok, v} -> {:ok, v}
      {:refused, m} -> {:refused, m}
      {:err, :value, t, m} -> {:value_error, "#{t}: #{m}"}
      {:err, :os, t, m} -> {:os_error, "#{t}: #{m}"}
      {:err, :url, t, m} -> {:url_error, "#{t}: #{m}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, r -> {:error, Exception.format_banner(kind, r)}
  end

  # ------------------------------------------------------------------ helpers --

  defp log(msg), do: Sys.log("alnasl-system-update", msg)

  defp seam(key), do: Keyword.get(Application.get_env(:alnasl_setup, :system_update, []), key)

  defp sleep(s) do
    case seam(:sleep) do
      f when is_function(f, 1) -> f.(s)
      _ -> Process.sleep(round(s * 1000))
    end
  end

  defp monotonic do
    case seam(:monotonic) do
      f when is_function(f, 0) -> f.()
      _ -> System.monotonic_time(:microsecond) / 1_000_000
    end
  end

  @doc "Local time as \"%Y-%m-%d %H:%M:%S %z\" (Python's now())."
  def now do
    secs = :os.system_time(:second)
    local = :calendar.system_time_to_local_time(secs, :second)
    utc = :calendar.system_time_to_universal_time(secs, :second)
    off = div(:calendar.datetime_to_gregorian_seconds(local) - :calendar.datetime_to_gregorian_seconds(utc), 60)
    {{y, mo, d}, {h, mi, s}} = local
    sign = if off < 0, do: "-", else: "+"
    a = abs(off)

    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B ~s~2..0B~2..0B", [
      y,
      mo,
      d,
      h,
      mi,
      s,
      sign,
      div(a, 60),
      rem(a, 60)
    ])
    |> IO.iodata_to_binary()
  end

  defp read(p, default \\ ""), do: Sys.read(p, default)

  # Python's str.splitlines (the line breaks a text file has).
  defp split_lines(""), do: []

  defp split_lines(s) do
    parts = String.split(s, ~r/\r\n|[\r\n\x0b\x0c\x1c-\x1e]/)
    if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
  end

  @doc """
  Write a file so that a reader sees the old or the new one, never half of it. v7.1: one temporary name
  per process. With one shared ".new", the boot check and the after-boot --check wrote the same file at
  once, one renamed it from under the other, and the boot check of a trial boot died on its first line
  (FileNotFoundError; seen in qemu on 6.2 and 7.1). Synced before the rename; the name itself is
  replaced (a symlink there is replaced, not followed: os.replace).
  """
  def write_atomic(p, text, mode \\ 0o644) do
    real = Sys.path(p)
    File.mkdir_p!(Path.dirname(real))
    tmp = "#{real}.new.#{System.pid()}"
    write_synced!(tmp, text, [:write])
    File.chmod!(tmp, mode)
    File.rename!(tmp, real)
    :ok
  end

  defp write_synced!(real, data, modes) do
    case :file.open(real, [:raw, :binary | modes]) do
      {:ok, fd} ->
        try do
          :ok = ok!(:file.write(fd, data), "write", real)
          :ok = ok!(:file.sync(fd), "sync", real)
        after
          :file.close(fd)
        end

      {:error, r} ->
        ferr!(r, "open", real)
    end
  end

  defp ok!(:ok, _, _), do: :ok
  defp ok!({:error, r}, action, path), do: ferr!(r, action, path)

  defp run(argv, timeout \\ 60), do: Sys.run(argv, timeout: timeout, stderr: :merge)

  defp sync, do: run(["sync"])

  defp kv_file(p) do
    for line <- split_lines(read(p)), m = Regex.run(re(:kv), line), m != nil, into: %{} do
      [_, k, v] = m
      {k, v}
    end
  end

  # Python's repr() and str() of what JSON can hold, for the sentences that printed them.
  defp py_repr(nil), do: "None"
  defp py_repr(true), do: "True"
  defp py_repr(false), do: "False"
  defp py_repr(i) when is_integer(i), do: Integer.to_string(i)
  defp py_repr(f) when is_float(f), do: :erlang.float_to_binary(f, [:short])

  defp py_repr(s) when is_binary(s) do
    q = if String.contains?(s, "'") and not String.contains?(s, "\""), do: "\"", else: "'"

    body =
      s
      |> Json.scrub()
      |> String.replace("\\", "\\\\")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")
      |> then(fn b -> if q == "'", do: String.replace(b, "'", "\\'"), else: b end)

    q <> body <> q
  end

  defp py_repr(l) when is_list(l), do: "[" <> Enum.map_join(l, ", ", &py_repr/1) <> "]"

  defp py_repr(t) when is_tuple(t) do
    "(" <> Enum.map_join(Tuple.to_list(t), ", ", &py_repr/1) <> ")"
  end

  defp py_repr(m) when is_map(m),
    do: "{" <> Enum.map_join(m, ", ", fn {k, v} -> py_repr(k) <> ": " <> py_repr(v) end) <> "}"

  defp py_repr(other), do: inspect(other)

  defp py_str(s) when is_binary(s), do: s
  defp py_str(v), do: py_repr(v)

  defp take_chars(s, n), do: s |> String.codepoints() |> Enum.take(n) |> Enum.join()

  # json.dumps(v, indent=1, sort_keys=True)
  defp pretty(v, level \\ 0)
  defp pretty(m, _) when is_map(m) and map_size(m) == 0, do: "{}"

  defp pretty(m, level) when is_map(m) do
    pad = String.duplicate(" ", level + 1)

    items =
      m
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> pad <> Json.encode(k) <> ": " <> pretty(v, level + 1) end)

    "{\n" <> Enum.join(items, ",\n") <> "\n" <> String.duplicate(" ", level) <> "}"
  end

  defp pretty([], _), do: "[]"

  defp pretty(l, level) when is_list(l) do
    pad = String.duplicate(" ", level + 1)
    "[\n" <> Enum.map_join(l, ",\n", &(pad <> pretty(&1, level + 1))) <> "\n" <> String.duplicate(" ", level) <> "]"
  end

  defp pretty(v, _), do: Json.encode(v)

  # json.dumps of a dict in its insertion order (the trial file).
  defp ordered_json(pairs),
    do: "{" <> Enum.map_join(pairs, ", ", fn {k, v} -> Json.encode(k) <> ": " <> Json.encode(v) end) <> "}"

  defp to_int(i) when is_integer(i), do: i
  defp to_int(f) when is_float(f), do: trunc(f)

  defp to_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {i, ""} -> i
      _ -> value_error("invalid literal for int() with base 10: #{py_repr(s)}")
    end
  end

  defp to_int(v), do: value_error("TypeError", "int() argument must be a string or a number, not #{py_repr(v)}")

  # ----------------------------------------------------------------- versions --

  def train_no(train) do
    case is_binary(train) && Regex.run(re(:train), train) do
      [_, n] -> String.to_integer(n)
      _ -> value_error("not a train: #{py_repr(train)}")
    end
  end

  def vkey(version) do
    case is_binary(version) && Regex.run(re(:version), version) do
      [_, a, b] -> {String.to_integer(a), String.to_integer(b), 0}
      [_, a, b, c] -> {String.to_integer(a), String.to_integer(b), String.to_integer(c)}
      _ -> value_error("not a version: #{py_repr(version)}")
    end
  end

  @doc "This slot's image: its train and version (assemble.sh writes them)."
  def release do
    r = kv_file(@release_file)
    train = Map.get(r, "ALNASL_TRAIN", "")
    version = Map.get(r, "ALNASL_VERSION", "")
    train_no(train)
    vkey(version)
    {train, version}
  end

  # ----------------------------------------------------------------- grub env --
  # The block is kept as a list of {key, value} in the file's order (Python's dict): written back in the
  # same order, new keys at the end, so the bytes are what Python wrote.

  @doc "The grub environment block at `path` (a real path; default the box's) as an ordered list."
  def read_env(path \\ nil) do
    {real, shown} = env_path(path)

    data =
      case File.read(real) do
        {:ok, d} -> d
        {:error, r} -> ferr!(r, "read file", real)
      end

    if byte_size(data) != 1024 or not String.starts_with?(data, @env_head) do
      os_error("OSError", "#{shown} is not a 1024-byte grub environment block")
    end

    data
    |> binary_part(byte_size(@env_head), 1024 - byte_size(@env_head))
    |> ascii_replace()
    |> String.split("\n")
    |> Enum.reduce([], fn line, env ->
      if line != "" and not String.starts_with?(line, "#") and String.contains?(line, "=") do
        [k, v] = String.split(line, "=", parts: 2)
        env_put(env, [{k, v}])
      else
        env
      end
    end)
  end

  defp env_path(nil), do: {Sys.path(@grubenv), @grubenv}
  defp env_path(p), do: {p, p}

  defp ascii_replace(bin), do: for(<<c <- bin>>, into: "", do: if(c < 128, do: <<c>>, else: "�"))

  @doc "Python's env.update(...): known keys keep their place, new ones go at the end."
  def env_put(env, kw) do
    Enum.reduce(kw, env, fn {k, v}, acc ->
      k = to_string(k)
      v = to_string(v)
      if List.keymember?(acc, k, 0), do: List.keyreplace(acc, k, 0, {k, v}), else: acc ++ [{k, v}]
    end)
  end

  def env_get(env, k) do
    case List.keyfind(env, k, 0) do
      {_, v} -> v
      nil -> nil
    end
  end

  @doc "In place, same blocks: grub's save_env writes into this file's blocks too, so it is never replaced."
  def write_env(env, path \\ nil) do
    {real, _} = env_path(path)

    body =
      Enum.reduce(env, @env_head, fn {k, v}, acc ->
        v = to_string(v)

        if not Regex.match?(re(:safe), k) or k == "" or not Regex.match?(re(:safe), v) do
          value_error("unsafe grub env entry #{py_repr(k)}=#{py_repr(v)}")
        end

        acc <> "#{k}=#{v}\n"
      end)

    if byte_size(body) > 1024, do: value_error("grub env too large")
    data = body <> String.duplicate("#", 1024 - byte_size(body))
    # "r+b": the file must be there (never created), and is not truncated
    unless File.exists?(real), do: ferr!(:enoent, "open", real)

    case :file.open(real, [:read, :write, :raw, :binary]) do
      {:ok, fd} ->
        try do
          ok!(:file.pwrite(fd, 0, data), "write", real)
          ok!(:file.sync(fd), "sync", real)
        after
          :file.close(fd)
        end

      {:error, r} ->
        ferr!(r, "open", real)
    end

    :ok
  end

  defp none?(v), do: v in [nil, "", "none"]

  # ----------------------------------------------------------------- the card --

  @doc "Where sysfs has the block device / is mounted from: /sys/dev/block/<major>:<minor>."
  def root_sysfs do
    st =
      case File.stat(Sys.path("/")) do
        {:ok, st} -> st
        {:error, r} -> ferr!(r, "stat", "/")
      end

    # st_dev, as glibc's major() and minor() take it apart
    dev = st.major_device
    maj = band(dev >>> 8, 0xFFF) ||| band(dev >>> 32, 0xFFFFF000)
    min = band(dev, 0xFF) ||| band(dev >>> 12, 0xFFFFFF00)
    "/sys/dev/block/#{maj}:#{min}"
  end

  @doc "{disk, partition name, partition number} of the partition / is mounted from."
  def root_part do
    case seam(:root_part) do
      f when is_function(f, 0) ->
        f.()

      _ ->
        sysdir = Sys.realpath(Sys.path(root_sysfs()))
        part = Path.basename(sysdir)
        disk = Path.basename(Path.dirname(sysdir))

        n =
          case File.read(sysdir <> "/partition") do
            {:ok, t} -> String.trim(t)
            _ -> "0"
          end

        {disk, part, if(n == "", do: 0, else: to_int(n))}
    end
  end

  defp part_dev(disk, n) do
    base = "/sys/class/block/" <> disk

    entries =
      case File.ls(Sys.path(base)) do
        {:ok, l} -> Enum.sort(l)
        {:error, r} -> ferr!(r, "list directory", base)
      end

    found =
      Enum.find(entries, fn e ->
        p = "#{base}/#{e}/partition"
        Sys.regular?(p) and String.trim(read(p)) == Integer.to_string(n)
      end)

    case found do
      nil ->
        refuse("partition #{n} of #{disk} not found: this card does not have the v6 layout")

      e ->
        size = String.trim(read("#{base}/#{e}/size", "0"))
        {"/dev/" <> e, if(size == "", do: 0, else: to_int(size)) * 512}
    end
  end

  def current_slot do
    {_, _, n} = root_part()
    by_part = Map.get(%{2 => "A", 3 => "B"}, n)
    m = Regex.run(~r/(?:^|\s)alnasl\.slot=([AB])(?:\s|$)/, read("/proc/cmdline"))

    case m do
      [_, s] when by_part != nil and s != by_part ->
        log("cmdline says slot #{s}, / is on partition #{n}: trusting the partition")

      _ ->
        :ok
    end

    if by_part == nil, do: refuse("/ is on partition #{n}, not on a system slot (2 or 3)")
    by_part
  end

  defp other("A"), do: "B"
  defp other(_), do: "A"

  defp mounted_devices do
    for line <- split_lines(read("/proc/self/mountinfo")),
        [_, rest] <- [String.split(line, " - ")],
        [_, src | _] <- [String.split(rest)],
        into: MapSet.new() do
      Sys.realpath(Sys.path(src))
    end
  end

  def target_device(slot) do
    {disk, part, _} = root_part()
    {dev, size} = part_dev(disk, @partno[slot])
    if Path.basename(dev) == part, do: refuse("the target slot is the running one")
    if MapSet.member?(mounted_devices(), Sys.realpath(Sys.path(dev))), do: refuse("#{dev} is mounted")
    {rc, puuid} = run(["blkid", "-p", "-s", "PART_ENTRY_UUID", "-o", "value", Sys.path(dev)])
    puuid = puuid |> String.trim() |> String.downcase()

    if rc == 0 and puuid != "" and not String.starts_with?(puuid, @disk_id) do
      refuse("#{dev} belongs to another disk layout (#{puuid})")
    end

    {dev, size}
  end

  # ------------------------------------------------------------------- status --

  defp load_json(p) do
    case File.read(Sys.path(p)) do
      {:ok, data} ->
        case Json.decode(data) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @doc """
  Read, change, write the status under a lock of its own: two processes at once must not lose each
  other's fields. Returns the new status.
  """
  def save_status(changes) do
    lockfile = Sys.path(@status_lock)

    release =
      try do
        File.mkdir_p!(Path.dirname(lockfile))

        case flock(lockfile, :block) do
          {:ok, rel} -> rel
          _ -> nil
        end
      rescue
        # no lock is better than no status
        _ -> nil
      end

    try do
      s =
        load_json(@status)
        |> Map.merge(Map.new(changes, fn {k, v} -> {to_string(k), v} end))
        |> Map.put("updated_at", now())

      write_atomic(@status, pretty(s) <> "\n")
      s
    after
      if release, do: release.()
    end
  end

  @doc "The result the menu and the diagnostics show: one file for the last one, a history line each."
  def record(outcome, note, extra \\ []) do
    w = now()
    r = [{"when", w}, {"outcome", outcome}, {"note", note}] ++ Enum.map(extra, fn {k, v} -> {to_string(k), v} end)
    save_status(%{"last_result" => Map.new(r)})

    write_atomic(
      @last,
      Enum.map_join(r, "", fn {k, v} -> String.pad_trailing(k <> ":", 9) <> " " <> py_str(v) <> "\n" end)
    )

    hist = Sys.path(@history)
    File.mkdir_p!(Path.dirname(hist))
    File.write!(hist, "#{w}  #{outcome}  #{note}\n", [:append])
    lines = read(@history) |> split_lines() |> Enum.take(-60)
    write_atomic(@history, Enum.join(lines, "\n") <> "\n")
    log("#{outcome}: #{note}")
  end

  defp splash(args), do: run([@splash | args], 20)

  @doc "Status (for the menu) and the boot screen (value + bar), at most every second / 1 %."
  def progress_new(phase, state, show_value, screen) do
    save_status(%{"phase" => phase, "progress" => 0})

    if screen do
      splash(["--progress", "0"])
      splash(["--value", if(show_value, do: "0%", else: "clear")])
      splash(["--set", state])
    end

    %{phase: phase, state: state, show_value: show_value, screen: screen, last_pct: -1, last_t: 0.0}
  end

  defp progress(p, done, total) do
    pct = if total != 0, do: div(done * 100, total), else: 0
    t = monotonic()

    if pct != p.last_pct and (t - p.last_t >= 1 or pct == 100) do
      save_status(%{"phase" => p.phase, "progress" => pct})

      if p.screen do
        splash(["--progress", Integer.to_string(pct)])
        if p.show_value, do: splash(["--value", "#{pct}%"])
      end

      %{p | last_pct: pct, last_t: t}
    else
      p
    end
  end

  defp clear_screen do
    splash(["--value", "clear"])
    splash(["--progress", "clear"])
    splash(["--set", "clear"])
  end

  # -------------------------------------------------------------------- trust --

  @doc "{usable, why not}. The image ships a placeholder until a real public key is put in at build time."
  def key_state do
    k = read(@key)

    cond do
      k == "" ->
        {false, "no update key in this image (#{@key})"}

      String.contains?(k, "ALNASL-PLACEHOLDER") or not String.contains?(k, "BEGIN PUBLIC KEY") ->
        {false, "this image carries the placeholder update key: system updates are off"}

      true ->
        {true, ""}
    end
  end

  @doc "openssl dgst -sha256 -verify KEY -signature SIG FILE (box paths), or Refused."
  def verify_sig(path, sig) do
    {rc, out} =
      run(["openssl", "dgst", "-sha256", "-verify", Sys.path(@key), "-signature", Sys.path(sig), Sys.path(path)], 900)

    if rc != 0 or not String.contains?(out, "Verified OK") do
      refuse("the signature of #{Path.basename(path)} does not match this image's update key")
    end

    :ok
  end

  # ---------------------------------------------------------------- http --
  # OTP's httpc, TLS checked against the system's CA store with the host name verified (Python's default
  # context). Redirects are followed here, never by httpc: GitHub's release downloads redirect to its
  # storage; follow that, but never to plain http (:https_only). The local probes (:any) follow what
  # urllib's default opener followed (http or https). Timeouts are per wait, like a socket timeout.

  @redirects [301, 302, 303, 307, 308]
  @reasons %{
    200 => "OK",
    206 => "Partial Content",
    301 => "Moved Permanently",
    302 => "Found",
    303 => "See Other",
    307 => "Temporary Redirect",
    308 => "Permanent Redirect",
    400 => "Bad Request",
    401 => "Unauthorized",
    403 => "Forbidden",
    404 => "Not Found",
    416 => "Requested Range Not Satisfiable",
    500 => "Internal Server Error",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Gateway Timeout"
  }

  defp http_error(status, reason), do: url_error("HTTPError", "HTTP Error #{status}: #{reason}")

  defp ensure_http do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  defp ssl_opts do
    cacerts =
      try do
        :public_key.cacerts_get()
      rescue
        _ -> url_error("URLError", "<urlopen error no CA certificates on this box>")
      end

    [
      verify: :verify_peer,
      cacerts: cacerts,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  # {:body, binary} for a 2xx answer that was not streamed, {:stream, handle} for 200/206 (the handle has
  # the headers), or an HTTPError / URLError.
  defp open_get(url, headers, timeout, mode, hops \\ 0) do
    ensure_http()
    uri = URI.parse(url)

    if uri.scheme not in ["http", "https"] or uri.host in [nil, ""] do
      url_error("URLError", "<urlopen error unknown url type: #{uri.scheme}>")
    end

    ms = round(timeout * 1000)
    req = {String.to_charlist(url), Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}

    http_opts =
      [timeout: :infinity, connect_timeout: ms, autoredirect: false] ++
        if(uri.scheme == "https", do: [ssl: ssl_opts()], else: [])

    ref =
      case :httpc.request(:get, req, http_opts, sync: false, stream: {:self, :once}, body_format: :binary) do
        {:ok, ref} -> ref
        {:error, r} -> url_error("URLError", "<urlopen error #{inspect(r)}>")
      end

    receive do
      {:http, {^ref, :stream_start, hdrs, pid}} ->
        {:stream, %{ref: ref, pid: pid, headers: hdrs}}

      {:http, {^ref, {{_, status, reason}, hdrs, body}}} ->
        reason = to_string(reason)

        cond do
          status in 200..299 ->
            {:body, IO.iodata_to_binary(body)}

          status in @redirects ->
            loc = header(hdrs, "location") || header(hdrs, "uri")
            if loc == nil, do: http_error(status, reason)
            new = url |> URI.merge(loc) |> URI.to_string()
            low = String.downcase(new)

            ok =
              case mode do
                :https_only -> String.starts_with?(low, "https://")
                :any -> String.starts_with?(low, "https://") or String.starts_with?(low, "http://")
              end

            cond do
              not ok ->
                http_error(status, reason)

              hops >= 10 ->
                http_error(
                  status,
                  "The HTTP server returned a redirect error that would lead to an infinite loop.\nThe last 30x error message was:\n" <>
                    reason
                )

              true ->
                open_get(new, headers, timeout, mode, hops + 1)
            end

          true ->
            http_error(status, reason)
        end

      {:http, {^ref, {:error, r}}} ->
        url_error("URLError", "<urlopen error #{inspect(r)}>")
    after
      ms ->
        :httpc.cancel_request(ref)
        flush(ref)
        url_error("URLError", "<urlopen error timed out>")
    end
  end

  defp header(hdrs, name) do
    Enum.find_value(hdrs, fn {k, v} -> if String.downcase(to_string(k)) == name, do: to_string(v) end)
  end

  defp next_chunk(%{ref: ref, pid: pid} = h, timeout) do
    :ok = :httpc.stream_next(pid)

    receive do
      {:http, {^ref, :stream, bin}} -> {:data, bin}
      {:http, {^ref, :stream_end, _}} -> :eof
      {:http, {^ref, {:error, r}}} -> os_error("ConnectionError", "the connection broke off (#{inspect(r)})")
    after
      round(timeout * 1000) ->
        cancel(h)
        os_error("TimeoutError", "The read operation timed out")
    end
  end

  defp cancel(%{ref: ref}) do
    :httpc.cancel_request(ref)
    flush(ref)
  end

  defp flush(ref) do
    receive do
      {:http, {^ref, _}} -> flush(ref)
      {:http, {^ref, _, _}} -> flush(ref)
      {:http, {^ref, _, _, _}} -> flush(ref)
    after
      0 -> :ok
    end
  end

  # At most `max` bytes of the body of a GET.
  defp get_body(url, max, timeout, mode) do
    case seam(:http) do
      f when is_function(f, 2) ->
        case f.(url, %{limit: max, timeout: timeout, redirects: mode}) do
          {:ok, status, body} when status in 200..299 -> binary_part(body, 0, min(byte_size(body), max))
          {:ok, status, _} -> http_error(status, Map.get(@reasons, status, ""))
          {:error, r} -> url_error("URLError", "<urlopen error #{inspect(r)}>")
        end

      _ ->
        case open_get(url, @ua, timeout, mode) do
          {:body, body} -> binary_part(body, 0, min(byte_size(body), max))
          {:stream, h} -> read_upto(h, max, timeout, [], 0)
        end
    end
  end

  defp read_upto(h, max, timeout, acc, n) do
    if n >= max do
      cancel(h)
      acc |> IO.iodata_to_binary() |> binary_part(0, max)
    else
      case next_chunk(h, timeout) do
        {:data, bin} -> read_upto(h, max, timeout, [acc | bin], n + byte_size(bin))
        :eof -> acc |> IO.iodata_to_binary() |> binary_part(0, min(n, max))
      end
    end
  end

  @doc "GET `url` (https-only redirects), refused when the body is larger than `limit` bytes."
  def fetch(url, limit) do
    data = get_body(url, limit + 1, 30, :https_only)
    if byte_size(data) > limit, do: refuse("#{url} is larger than #{limit} bytes")
    data
  end

  defp https?(url) do
    is_binary(url) and String.valid?(url) and String.starts_with?(url, "https://") and
      length(String.codepoints(url)) < 500 and not Regex.match?(~r/[\s\x00-\x1f]/u, url)
  end

  def index_url do
    st = load_json(@setup_state)
    u = Map.get(st, "update_url")

    if u not in [nil, ""] and https?(u) do
      u
    else
      u = Map.get(kv_file(@update_conf), "INDEX_URL", "")
      if https?(u), do: u, else: @default_index
    end
  end

  defp truthy?(v), do: v not in [nil, false, "", 0, [], %{}] and v != 0.0

  defp entry_ok?(i) do
    case catching(fn ->
           is_map(i) and train_no(i["train"]) == elem(vkey(i["version"]), 0) and https?(i["url"]) and
             https?(i["sig_url"]) and is_integer(i["size"]) and i["size"] > 0 and i["size"] <= @max_image and
             is_integer(i["raw_size"]) and i["raw_size"] > 0 and i["raw_size"] <= @max_image and
             is_binary(i["sha256"]) and Regex.match?(re(:sha), i["sha256"]) and is_binary(i["raw_sha256"]) and
             Regex.match?(re(:sha), i["raw_sha256"]) and is_binary(i["file"]) and Regex.match?(re(:file), i["file"]) and
             (not truthy?(i["min_from"]) or is_tuple(vkey(i["min_from"])))
         end) do
      {:ok, ok} -> ok
      _ -> false
    end
  end

  @doc "The images of a release index (its bytes) that are complete and consistent, or Refused."
  def parse_index(data) do
    unless String.valid?(data), do: value_error("UnicodeDecodeError", "'utf-8' codec can't decode the release index")

    j =
      case Json.decode(data) do
        {:ok, j} -> j
        _ -> value_error("JSONDecodeError", "the release index is not JSON")
      end

    unless is_map(j) and j["format"] == 1 and is_list(j["images"]) do
      refuse("the release index has an unknown format")
    end

    Enum.filter(j["images"], fn i ->
      ok = entry_ok?(i)
      unless ok, do: log("index entry skipped (incomplete or inconsistent): #{py_repr(if is_map(i), do: i, else: "?")}")
      ok
    end)
  end

  defp get_index do
    url = index_url()
    {ok, why} = key_state()
    unless ok, do: refuse(why)
    File.mkdir_p!(Sys.path(@dl))
    idx = @dl <> "/index.json"
    sig = @dl <> "/index.json.sig"
    data = fetch(url, 1 <<< 20)
    File.write!(Sys.path(idx), data)
    File.write!(Sys.path(sig), fetch(url <> ".sig", 16384))
    verify_sig(idx, sig)
    parse_index(data)
  end

  @doc """
  What this box may do. same: the newest image of its own train it can go to by itself.
  offer: the newest image of a LATER train it may be upgraded to - only ever on request.
  blocked: a later train exists but needs a newer version of this train first.
  """
  def choose(images, train, version) do
    me = vkey(version)
    reach = fn i -> not truthy?(i["min_from"]) or vkey(i["min_from"]) <= me end
    same = Enum.filter(images, &(&1["train"] == train and vkey(&1["version"]) > me and reach.(&1)))
    later = Enum.filter(images, &(train_no(&1["train"]) > train_no(train)))
    offer = Enum.filter(later, reach)
    best = if same != [], do: Enum.max_by(same, &vkey(&1["version"]))
    up = if offer != [], do: Enum.max_by(offer, &{train_no(&1["train"]), vkey(&1["version"])})

    blocked =
      if later != [] and offer == [] do
        case Enum.filter(later, &truthy?(&1["min_from"])) do
          [] -> nil
          need -> Enum.min_by(need, &vkey(&1["min_from"]))["min_from"]
        end
      end

    {best, up, blocked}
  end

  @doc "The rule: never move to another train unless that train was asked for explicitly."
  def train_guard(img, my_train, asked_train \\ nil) do
    if train_no(img["train"]) != elem(vkey(img["version"]), 0) do
      refuse("image #{img["version"]} does not belong to train #{img["train"]}")
    end

    cond do
      img["train"] == my_train ->
        :ok

      asked_train not in [nil, ""] and img["train"] == asked_train and train_no(asked_train) > train_no(my_train) ->
        :ok

      true ->
        refuse(
          "image #{img["version"]} is of train #{img["train"]}; this box is on #{my_train} and changes trains only when asked to (Upgrade to #{img["train"]})"
        )
    end
  end

  defp brief(nil), do: nil

  defp brief(i) do
    %{
      "train" => i["train"],
      "version" => i["version"],
      "size" => i["size"],
      "released" => Map.get(i, "released", ""),
      "notes" => take_chars(py_str(Map.get(i, "notes", "")), 400)
    }
  end

  @doc "Reads the index into the status; {best, up, blocked, images} (nils and [] when it could not)."
  def check do
    {train, version} = release()
    save_status(%{"phase" => "checking", "progress" => nil})

    failed = fn why ->
      save_status(%{"phase" => "idle", "checked_at" => now(), "check_error" => why})
      log("check: " <> why)
      {nil, nil, nil, []}
    end

    case catching(&get_index/0) do
      {:refused, why} ->
        failed.(why)

      {:err, _, type, _} ->
        failed.("could not read the release index (#{type})")

      {:ok, images} ->
        {best, up, blocked} = choose(images, train, version)

        save_status(%{
          "phase" => "idle",
          "checked_at" => now(),
          "check_error" => nil,
          "available" => brief(best),
          "offer" => brief(up),
          "offer_blocked" => blocked,
          "index_url" => index_url()
        })

        log(
          "check: on #{train} #{version}; this train: #{if best, do: best["version"], else: "nothing newer"}; later train: " <>
            "#{if up, do: "#{up["train"]} #{up["version"]}", else: "none"}#{if blocked, do: " (needs #{blocked} first)", else: ""}"
        )

        {best, up, blocked, images}
    end
  end

  # ----------------------------------------------------------------- download --

  @doc "Resumes a partial file (.part); the size and the hash are checked by the caller."
  def download(url, dest, size, prog) do
    part = dest <> ".part"
    rpart = Sys.path(part)
    File.mkdir_p!(Path.dirname(rpart))

    have =
      case File.stat(rpart) do
        {:ok, st} -> st.size
        _ -> 0
      end

    have =
      if have > size do
        File.rm!(rpart)
        0
      else
        have
      end

    hdr = @ua ++ if(have > 0, do: [{"Range", "bytes=#{have}-"}], else: [])

    {src, partial} =
      case open_get(url, hdr, 60, :https_only) do
        {:body, body} -> {{:body, body}, false}
        # only a 206 has a Content-Range (httpc streams 200 and 206 alike)
        {:stream, h} -> {{:stream, h}, header(h.headers, "content-range") != nil}
      end

    have = if have > 0 and not partial, do: 0, else: have

    fd =
      case :file.open(rpart, [:raw, :binary, if(have > 0, do: :append, else: :write)]) do
        {:ok, fd} -> fd
        {:error, r} -> ferr!(r, "open", rpart)
      end

    try do
      download_loop(src, fd, rpart, have, size, prog)
      ok!(:file.sync(fd), "sync", rpart)
    after
      :file.close(fd)
    end

    File.rename!(rpart, Sys.path(dest))
    :ok
  end

  defp download_loop(src, fd, rpart, done, size, prog) do
    {got, rest} =
      case src do
        {:body, body} -> {{:data, body}, :done}
        {:stream, h} -> {next_chunk(h, 60), src}
        :done -> {:eof, :done}
      end

    case got do
      :eof ->
        :ok

      {:data, chunk} ->
        done = done + byte_size(chunk)

        if done > size do
          with {:stream, h} <- src, do: cancel(h)
          refuse("the download is larger than the index says")
        end

        ok!(:file.write(fd, chunk), "write", rpart)
        download_loop(rest, fd, rpart, done, size, progress(prog, done, size))
    end
  end

  @doc "sha256 of a file (a real path), read 4 MiB at a time."
  def sha256_file(real) do
    case :file.open(real, [:read, :raw, :binary]) do
      {:ok, fd} ->
        try do
          hash_loop(fd, :crypto.hash_init(:sha256), real)
        after
          :file.close(fd)
        end

      {:error, r} ->
        ferr!(r, "open", real)
    end
  end

  defp hash_loop(fd, ctx, real) do
    case :file.read(fd, 4 <<< 20) do
      {:ok, data} -> hash_loop(fd, :crypto.hash_update(ctx, data), real)
      :eof -> ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
      {:error, r} -> ferr!(r, "read", real)
    end
  end

  defp disk_free(dir) do
    {rc, out} = run(["df", "--output=avail", "-B1", Sys.path(dir)], 30)

    with 0 <- rc, [_, n | _] <- String.split(out, "\n", trim: true), {free, ""} <- Integer.parse(String.trim(n)) do
      free
    else
      _ -> os_error("OSError", "could not tell the free space of #{dir}: #{String.trim(out)}")
    end
  end

  defp file_size(p) do
    case File.stat(Sys.path(p)) do
      {:ok, st} -> st.size
      {:error, r} -> ferr!(r, "stat", Sys.path(p))
    end
  end

  defp fetch_image(img, screen) do
    dl = Sys.path(@dl)
    File.mkdir_p!(dl)

    # an older download is of no use any more
    for f <- File.ls!(dl), String.starts_with?(f, "alnasl-system-") and not String.starts_with?(f, img["file"]) do
      File.rm!(Path.join(dl, f))
    end

    free = disk_free(@dl)
    path = @dl <> "/" <> img["file"]
    exists = File.exists?(Sys.path(path))

    if free < img["size"] + (256 <<< 20) and not exists do
      refuse("not enough room on the data partition for the download (#{free >>> 20} MB free)")
    end

    unless exists and file_size(path) == img["size"] do
      download(img["url"], path, img["size"], progress_new("downloading", "update-download", true, screen))
    end

    File.write!(Sys.path(path <> ".sig"), fetch(img["sig_url"], 16384))

    if file_size(path) != img["size"] or sha256_file(Sys.path(path)) != img["sha256"] do
      File.rm!(Sys.path(path))
      refuse("the downloaded image does not match the index (size or checksum)")
    end

    save_status(%{"phase" => "verifying", "progress" => nil})
    verify_sig(path, path <> ".sig")
    path
  end

  # ----------------------------------------------------------------- the slot --

  @doc "Unpacks the image into the other slot, reads it back from the card, labels it. Returns the device."
  def write_slot(img, path, slot, screen) do
    {dev, size} = target_device(slot)
    raw = img["raw_size"]

    if raw > size do
      refuse("the image (#{raw >>> 20} MB) does not fit in slot #{slot} (#{size >>> 20} MB)")
    end

    prog = progress_new("installing", "update-install", false, screen)

    dec =
      if String.ends_with?(path, ".zst"),
        do: ["zstd", "-dc", "--no-progress", Sys.path(path)],
        else: ["xz", "-dc", Sys.path(path)]

    log("writing #{img["version"]} into slot #{slot} (#{dev})")
    rdev = Sys.path(dev)
    {rc, done, digest, prog} = unpack_into(dec, rdev, raw, prog)

    if rc != 0 or done != raw or digest != img["raw_sha256"] do
      refuse("the image did not unpack to what the index says (#{done} of #{raw} bytes)")
    end

    # Read it back from the card, not from the page cache: what grub will boot is what is on the card.
    run(["blockdev", "--flushbufs", rdev])
    drop = Sys.path("/proc/sys/vm/drop_caches")

    case File.write(drop, "1\n") do
      :ok -> :ok
      {:error, r} -> ferr!(r, "open", drop)
    end

    {left, digest} = read_back(rdev, raw, prog)

    if left != 0 or digest != img["raw_sha256"] do
      refuse("slot #{slot} does not read back as written: the card may be failing")
    end

    {rc, out} = run(["e2label", rdev, @label[slot]])
    if rc != 0, do: refuse("could not label slot #{slot}: #{String.trim(out)}")
    log("slot #{slot} holds #{img["version"]}, read back and checked")
    dev
  end

  # The decompressor writes into a FIFO, this process reads it 4 MiB at a time and writes the card: the
  # pipe holds zstd back while the card is slower (a port would deliver all of it into the mailbox).
  defp unpack_into([cmd | args], rdev, raw, prog) do
    exe =
      System.find_executable(cmd) ||
        os_error("FileNotFoundError", "[Errno 2] No such file or directory: '#{cmd}'")

    unless File.exists?(rdev), do: ferr!(:enoent, "open", rdev)

    out =
      case :file.open(rdev, [:read, :write, :raw, :binary]) do
        {:ok, fd} -> fd
        {:error, r} -> ferr!(r, "open", rdev)
      end

    fifo = Sys.path(@dl <> "/unpack.fifo")
    File.mkdir_p!(Path.dirname(fifo))
    File.rm(fifo)
    {rc, msg} = run(["mkfifo", "-m", "600", fifo], 10)

    if rc != 0 do
      :file.close(out)
      os_error("OSError", "could not make #{fifo}: #{String.trim(msg)}")
    end

    # sh only for the redirection; the program and its arguments go in as argv (stderr: the journal)
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :hide,
        {:env, [{~c"ALNASL_FIFO", String.to_charlist(fifo)}]},
        {:args, ["-c", "exec \"$0\" \"$@\" >\"$ALNASL_FIFO\"", exe | args]}
      ])

    # Should the writer never open its end (sh could not), a watchdog opens it and closes it again, so
    # the open below returns and reads an empty image.
    dog =
      spawn(fn ->
        receive do
          :opened -> :ok
        after
          60_000 ->
            case :file.open(fifo, [:write, :raw]) do
              {:ok, w} -> :file.close(w)
              _ -> :ok
            end
        end
      end)

    result =
      try do
        inp =
          case :file.open(fifo, [:read, :raw, :binary]) do
            {:ok, fd} -> fd
            {:error, r} -> ferr!(r, "open", fifo)
          end

        send(dog, :opened)

        try do
          res = copy_loop(inp, out, raw, 0, :crypto.hash_init(:sha256), prog, rdev)
          ok!(:file.sync(out), "sync", rdev)
          {:ok, res}
        after
          :file.close(inp)
        end
      catch
        kind, reason -> {:raise, kind, reason, __STACKTRACE__}
      after
        :file.close(out)
      end

    Process.exit(dog, :kill)
    # With its reader gone the decompressor stops (SIGPIPE); it is never left running.
    rc = port_exit(port)
    File.rm(fifo)

    case result do
      {:ok, {done, digest, prog}} -> {rc, done, digest, prog}
      {:raise, kind, reason, st} -> :erlang.raise(kind, reason, st)
    end
  end

  defp copy_loop(inp, out, raw, done, ctx, prog, rdev) do
    case :file.read(inp, 4 <<< 20) do
      :eof ->
        {done, ctx |> :crypto.hash_final() |> Base.encode16(case: :lower), prog}

      {:ok, chunk} ->
        done = done + byte_size(chunk)
        if done > raw, do: refuse("the image unpacks to more than the index says")
        ctx = :crypto.hash_update(ctx, chunk)
        ok!(:file.write(out, chunk), "write", rdev)
        prog = progress(prog, div(done * 70, raw), 100)
        copy_loop(inp, out, raw, done, ctx, prog, rdev)

      {:error, r} ->
        ferr!(r, "read", "the decompressor's output")
    end
  end

  defp port_exit(port) do
    receive do
      {^port, {:exit_status, rc}} -> rc
    after
      30_000 ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} ->
            System.cmd("sh", ["-c", "kill -9 \"$1\"", "sh", Integer.to_string(pid)], stderr_to_stdout: true)

          _ ->
            :ok
        end

        receive do
          {^port, {:exit_status, rc}} -> rc
        after
          5000 -> 137
        end
    end
  end

  defp read_back(rdev, raw, prog) do
    fd =
      case :file.open(rdev, [:read, :raw, :binary]) do
        {:ok, fd} -> fd
        {:error, r} -> ferr!(r, "open", rdev)
      end

    try do
      :file.advise(fd, 0, 0, :dont_need)
      back_loop(fd, raw, raw, :crypto.hash_init(:sha256), prog, rdev)
    after
      :file.close(fd)
    end
  end

  defp back_loop(_fd, 0, _raw, ctx, _prog, _), do: {0, ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)}

  defp back_loop(fd, left, raw, ctx, prog, rdev) do
    case :file.read(fd, min(4 <<< 20, left)) do
      {:ok, chunk} ->
        left = left - byte_size(chunk)
        prog = progress(prog, 70 + div((raw - left) * 30, raw), 100)
        back_loop(fd, left, raw, :crypto.hash_update(ctx, chunk), prog, rdev)

      :eof ->
        {left, ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      {:error, r} ->
        ferr!(r, "read", rdev)
    end
  end

  defp vfile(path) do
    v = String.trim(read(path))

    case catching(fn -> vkey(v) end) do
      {:ok, k} -> {v, k}
      _ -> {v, nil}
    end
  end

  def box_role do
    w = read(@mode_file) |> String.trim() |> String.downcase()
    w = Map.get(@role_aliases, w, w)
    if Map.has_key?(@role_app, w), do: w, else: "alnasl"
  end

  # shutil.copy2: content, mode and times (not the owner)
  defp copy2(src, dst) do
    File.cp!(src, dst)
    copystat(src, dst)
  end

  defp copystat(src, dst) do
    {:ok, st} = File.stat(src, time: :posix)
    :file.write_file_info(dst, file_info(mode: st.mode, atime: st.atime, mtime: st.mtime), time: :posix)
  end

  # shutil.copytree(symlinks=True)
  defp copytree(src, dst) do
    File.mkdir_p!(dst)

    for name <- File.ls!(src) do
      s = Path.join(src, name)
      d = Path.join(dst, name)

      case File.lstat!(s).type do
        :symlink ->
          {:ok, target} = File.read_link(s)
          File.ln_s!(target, d)

        :directory ->
          copytree(s, d)

        _ ->
          copy2(s, d)
      end
    end

    copystat(src, dst)
  end

  @doc "One app's newer release (its own updater wrote it into this slot's /opt/<app>) into the new slot."
  def carry_app(app, mine) do
    dst = Sys.path(@newslot <> "/opt/#{app}/releases/#{mine}")
    File.rm_rf(dst)
    copytree(Sys.path("/opt/#{app}/releases/#{mine}"), dst)
    tmp = Sys.path(@newslot <> "/opt/#{app}/current.new")
    if match?({:ok, _}, File.lstat(tmp)), do: File.rm!(tmp)
    File.ln_s!("releases/" <> mine, tmp)
    File.rename!(tmp, Sys.path(@newslot <> "/opt/#{app}/current"))

    for f <- [
          "/opt/#{app}/update.sh",
          "/opt/#{app}/uninstall.sh",
          "/etc/systemd/system/#{app}.service",
          "/etc/systemd/system/#{app}-update.service",
          "/etc/systemd/system/#{app}-update.path"
        ],
        Sys.regular?(f) do
      copy2(Sys.path(f), Sys.path(@newslot <> f))
    end

    :ok
  end

  @doc """
  What the new slot must know of this one: the identity PID 1 reads before any mount (machine id,
  name, console keymap), the next boot's picture, and each app (Alnasl, and v7: Arkab, Polis, Nunki)
  when this slot has a newer one than the image (its app updater writes /opt/<app>; going back a
  version would meet a database it migrated). The role itself is on the data partition: nothing to carry.
  """
  def carry_over(dev, img) do
    File.mkdir_p!(Sys.path(@newslot))
    {rc, out} = run(["mount", "-o", "rw,noatime", Sys.path(dev), Sys.path(@newslot)])
    if rc != 0, do: refuse("could not mount the new slot: #{String.trim(out)}")

    try do
      r = kv_file(@newslot <> @release_file)

      if r["ALNASL_TRAIN"] != img["train"] or r["ALNASL_VERSION"] != img["version"] do
        refuse(
          "the new slot says it is #{py_str(r["ALNASL_TRAIN"])} #{py_str(r["ALNASL_VERSION"])}, the index said #{img["train"]} #{img["version"]}"
        )
      end

      for f <- ["/etc/machine-id", "/etc/hostname", "/etc/vconsole.conf"],
          Sys.regular?(f) and not match?({:ok, %{type: :symlink}}, File.lstat(Sys.path(f))) do
        copy2(Sys.path(f), Sys.path(@newslot <> f))
      end

      File.mkdir_p!(Sys.path(@newslot <> "/var/lib/alnasl-screen"))
      write_atomic(@newslot <> "/var/lib/alnasl-screen/next-boot", "update-finish\n")

      for app <- @role_order do
        {mine, mk} = vfile("/opt/#{app}/current/VERSION")
        {theirs, tk} = vfile(@newslot <> "/opt/#{app}/current/VERSION")

        # an image without this app (a v6 one has no Polis or Nunki): nothing to put it in
        if Sys.dir?(@newslot <> "/opt/" <> app) and mk != nil and (tk == nil or mk > tk) and
             Sys.dir?("/opt/#{app}/releases/#{mine}") do
          log(
            "#{elem(@role_app[app], 0)} #{mine} here is newer than the image's #{if theirs == "", do: "?", else: theirs}: it goes along"
          )

          carry_app(app, mine)
        end
      end
    after
      sync()
      run(["umount", Sys.path(@newslot)])
    end
  end

  defp trial_pairs(t) do
    known = ~w(slot version train from boots started)

    Enum.flat_map(known, &if(Map.has_key?(t, &1), do: [{&1, t[&1]}], else: [])) ++
      (t |> Map.drop(known) |> Enum.sort())
  end

  defp flip_and_restart(slot, img, mine) do
    env =
      read_env()
      |> env_put(
        alnasl_try: slot,
        alnasl_tries: Integer.to_string(@tries),
        alnasl_try_version: img["version"],
        alnasl_try_from: mine,
        alnasl_failed: "none"
      )

    write_env(env)

    write_atomic(
      @trial,
      ordered_json([
        {"slot", slot},
        {"version", img["version"]},
        {"train", img["train"]},
        {"from", mine},
        {"boots", 0},
        {"started", now()}
      ]) <> "\n"
    )

    save_status(%{"phase" => "restarting", "progress" => nil, "staged" => nil})
    splash(["--progress", "clear"])
    splash(["--value", "v" <> img["version"]])
    splash(["--set", "update-restart"])
    log("restarting into slot #{slot} (#{img["train"]} #{img["version"]}), #{@tries} tries")
    sleep(3)
    sync()
    run(["systemctl", "reboot"])
  end

  defp in_window do
    {_, {h, _, _}} = :calendar.local_time()
    {from, to} = @window
    from <= h and h < to
  end

  @doc "Download, check, write to the other slot, read back, carry over; restart now or leave it staged."
  def install(img, asked_train, restart, by) do
    {train, version} = release()
    train_guard(img, train, asked_train)
    if vkey(img["version"]) <= vkey(version), do: refuse("#{img["version"]} is not newer than #{version}")
    env = read_env()

    unless none?(env_get(env, "alnasl_try")) do
      refuse("a new slot is still on trial; nothing else installs until it is settled")
    end

    slot = other(current_slot())
    st = load_json(@status)
    staged = if is_map(st["staged"]), do: st["staged"], else: %{}
    screen = restart == true or (restart == "window" and in_window())

    dev =
      if not (staged["version"] == img["version"] and staged["slot"] == slot and staged["sha256"] == img["sha256"]) do
        path = fetch_image(img, screen)
        save_status(%{"staged" => nil})
        dev = write_slot(img, path, slot, screen)
        File.rm!(Sys.path(path))
        if File.exists?(Sys.path(path <> ".sig")), do: File.rm!(Sys.path(path <> ".sig"))

        save_status(%{
          "staged" => %{
            "version" => img["version"],
            "train" => img["train"],
            "slot" => slot,
            "sha256" => img["sha256"],
            "written" => now()
          },
          "phase" => "staged",
          "progress" => nil
        })

        record(
          "staged",
          "#{img["train"]} #{img["version"]} written to slot #{slot} and checked; waiting for the restart",
          version: img["version"],
          by: by
        )

        dev
      else
        {dev, _} = target_device(slot)
        log("slot #{slot} already holds #{img["version"]} (staged #{py_str(staged["written"])})")
        dev
      end

    if restart == true or (restart == "window" and in_window()) do
      carry_over(dev, img)
      flip_and_restart(slot, img, version)
      true
    else
      if screen, do: clear_screen()
      save_status(%{"phase" => "staged"})
      log("staged in slot #{slot}; the restart waits for the next quiet window")
      false
    end
  end

  # -------------------------------------------------------------- round check --

  def round_in_progress do
    if box_role() != "alnasl" do
      {false, "not an Alnasl box: no rounds here"}
    else
      case attempt(fn -> get_body(@alnasl_status_url, 2000, 4, :any) end) do
        {:ok, body} ->
          out = Json.scrub(body)

          cond do
            Regex.match?(~r/"round_in_progress"\s*:\s*true/, out) -> {true, "round in progress"}
            Regex.match?(~r/"round_in_progress"\s*:\s*false/, out) -> {false, "no round in progress"}
            true -> {false, "Alnasl gave no clear answer: treated as no round"}
          end

        _ ->
          {false, "Alnasl not running or not answering: treated as no round"}
      end
    end
  end

  # ------------------------------------------------------------------- locks --

  @doc """
  util-linux flock on `real_path`: `{:ok, release_fun}`, `:busy` (only with `:nb`) or `{:error, why}`.
  The lock is held by `flock <file> cat` running as a port of the calling process (see the moduledoc).
  The file is made 0600 first, as Python's os.open(..., 0o600) made it.
  """
  def flock(real_path, mode) when mode in [:nb, :block] do
    case seam(:lock) do
      f when is_function(f, 2) -> f.(real_path, mode)
      _ -> real_flock(real_path, mode)
    end
  end

  defp real_flock(path, mode) do
    with {:exe, exe} when exe != nil <- {:exe, System.find_executable("flock")},
         :ok <- lock_file(path) do
      args = if mode == :nb, do: ["-n", path, "cat"], else: [path, "cat"]
      port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :hide, args: args])

      try do
        Port.command(port, "locked\n")
      rescue
        ArgumentError -> :ok
      end

      wait_lock(port, mode, "")
    else
      {:exe, nil} -> {:error, "flock is not installed"}
      {:error, r} -> {:error, "#{path}: #{:file.format_error(r)}"}
    end
  end

  defp lock_file(path) do
    if File.exists?(path) do
      :ok
    else
      with :ok <- File.mkdir_p(Path.dirname(path)) do
        case File.write(path, "", [:exclusive]) do
          :ok -> File.chmod(path, 0o600)
          {:error, :eexist} -> :ok
          e -> e
        end
      end
    end
  end

  defp wait_lock(port, mode, acc) do
    receive do
      {^port, {:data, d}} ->
        acc = acc <> d

        if String.contains?(acc, "locked\n"),
          do: {:ok, fn -> close_port(port) end},
          else: wait_lock(port, mode, acc)

      {^port, {:exit_status, 1}} when mode == :nb ->
        :busy

      {^port, {:exit_status, rc}} ->
        {:error, "flock exited with #{rc}"}
    after
      if(mode == :nb, do: 10_000, else: :infinity) ->
        close_port(port)
        {:error, "flock did not answer"}
    end
  end

  defp close_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    receive do
      {^port, _} -> :ok
    after
      0 -> :ok
    end

    :ok
  end

  defp locked(fun) do
    path = Sys.path(@lock)
    File.mkdir_p!(Path.dirname(path))

    case flock(path, :nb) do
      {:ok, release} ->
        try do
          fun.()
        after
          release.()
        end

      :busy ->
        log("another run is busy; this one stops")
        4

      {:error, why} ->
        log("could not take the lock #{@lock} (#{why})")
        1
    end
  end

  defp guarded(by, fun) do
    case catching(fun) do
      {:ok, v} ->
        v

      {:refused, m} ->
        clear_screen()
        save_status(%{"phase" => "idle", "progress" => nil})
        record("refused", m, by: by)
        1

      {:err, _kind, type, m} ->
        clear_screen()
        save_status(%{"phase" => "idle", "progress" => nil})
        record("failed", "#{type}: #{m}", by: by)
        1
    end
  end

  # ------------------------------------------------------------------ commands --

  defp cmd_check do
    check()
    0
  end

  # Exit 3: restarting into a new slot (the caller stops). 4: busy or a trial is on (skip tonight's
  # package update too). 0: nothing to restart for (the caller goes on with the package update).
  defp cmd_nightly do
    case catching(fn -> read_env() end) do
      {:err, :os, _, m} ->
        log("no A/B boot environment (#{m}); system updates skipped")
        0

      {:ok, env} ->
        if not none?(env_get(env, "alnasl_try")) do
          log("a new slot is on trial; nothing tonight")
          4
        else
          case check() do
            {nil, _, _, _} -> 0
            {best, _, _, _} -> guarded("nightly", fn -> if install(best, nil, "window", "nightly"), do: 3, else: 4 end)
          end
        end
    end
  end

  @doc "The request file, consumed: a map with action install/upgrade (and a train), or nil."
  def take_request do
    case File.read(Sys.path(@request)) do
      {:ok, data} ->
        raw = if String.valid?(data), do: take_chars(data, 400), else: binary_part(data, 0, min(400, byte_size(data)))
        File.rm!(Sys.path(@request))

        ok =
          case Json.decode(raw) do
            {:ok, r} when is_map(r) ->
              r["action"] in ["install", "upgrade"] and
                (r["action"] != "upgrade" or match?({:ok, _}, catching(fn -> train_no(Map.get(r, "train", "")) end))) and
                r

            _ ->
              false
          end

        if ok do
          ok
        else
          log("the request was not understood; removed")
          nil
        end

      {:error, _} ->
        nil
    end
  end

  defp do_request(r) do
    by = take_chars(py_str(Map.get(r, "by", "menu")), 20)
    {busy, _why} = round_in_progress()

    if busy do
      save_status(%{"phase" => "idle", "request_error" => "round_in_progress"})
      record("skipped", "asked for by #{by}, but a round is in progress; nothing changed", by: by)
      1
    else
      save_status(%{"request_error" => nil})
      {best, _up, _blocked, images} = check()
      {train, version} = release()

      cond do
        r["action"] == "install" and best == nil ->
          record("nothing", "asked for by #{by}: there is nothing newer in train #{train}", by: by)
          0

        r["action"] == "install" ->
          guarded(by, fn -> if install(best, nil, true, by), do: 0, else: 1 end)

        r["train"] == train ->
          do_request(%{"action" => "install", "by" => by})

        true ->
          want = r["train"]
          cands = Enum.filter(images, &(&1["train"] == want))
          reach = Enum.filter(cands, &(not truthy?(&1["min_from"]) or vkey(&1["min_from"]) <= vkey(version)))

          cond do
            cands == [] ->
              record("refused", "asked for by #{by}: there is no image of train #{want}", by: by)
              1

            reach == [] ->
              need = cands |> Enum.map(&vkey(&1["min_from"])) |> Enum.min()
              record("refused", "#{want} needs at least #{py_repr(need)} first; this box has #{version}", by: by)
              1

            true ->
              img = Enum.max_by(reach, &vkey(&1["version"]))
              log("upgrade to #{want} asked for by #{by}: #{img["version"]}")
              guarded(by, fn -> if install(img, want, true, by), do: 0, else: 1 end)
          end
      end
    end
  end

  defp cmd_request do
    case take_request() do
      nil -> 0
      r -> do_request(r)
    end
  end

  # alnasl-upgrade.txt: one word, the train (v7). Consumed before anything else, like alnasl-reset.txt.
  defp cmd_boot_file do
    if not Sys.regular?(@boot_file) do
      0
    else
      word =
        (read(@boot_file) |> split_lines() |> List.first() || "")
        |> String.trim()
        |> String.trim_leading("﻿")

      File.rm!(Sys.path(@boot_file))
      sync()

      case catching(fn -> train_no(word) end) do
        {:ok, _} ->
          log("asked for by #{@boot_file}: #{word}")
          r = %{"action" => "upgrade", "train" => word, "by" => "boot-file"}

          # the network may need a while after boot (Wi-Fi from alnasl-wifi.txt ...)
          Enum.reduce_while(1..20, nil, fn _, _ ->
            reached =
              try do
                fetch(index_url(), 1 <<< 20)
                true
              catch
                _, _ -> false
              end

            if reached do
              {:halt, nil}
            else
              save_status(%{"phase" => "waiting"})
              sleep(30)
              {:cont, nil}
            end
          end)

          do_request(r)

        _ ->
          record("refused", "#{@boot_file} did not name a train (like v7) on its first line; removed it",
            by: "boot-file"
          )

          1
      end
    end
  end

  # --------------------------------------------------------------- boot check --

  defp answers(url) do
    case attempt(fn -> get_body(url, 1, 3, :any) end) do
      {:ok, _} -> true
      # it answered, with whatever status
      {:url_error, "HTTPError" <> _} -> true
      _ -> false
    end
  end

  defp enabled(unit) do
    {_, out} = run(["systemctl", "is-enabled", unit], 10)
    out |> String.trim() |> split_lines() |> Enum.take(-1) == ["enabled"]
  end

  # alnasl-kiosk-load is at work (or between two tries of it): the screen is on its way.
  defp kiosk_loading do
    {_, out} = run(["systemctl", "show", "-p", "ActiveState", "--value", "alnasl-kiosk-load.service"], 10)
    String.trim(out) in ["activating", "reloading"]
  end

  defp display_connected do
    base = "/sys/class/drm"

    case File.ls(Sys.path(base)) do
      {:ok, names} ->
        Enum.any?(names, &(String.contains?(&1, "-HDMI-") and String.trim(read("#{base}/#{&1}/status")) == "connected"))

      _ ->
        false
    end
  end

  @doc """
  {ok, what is missing}. The setup server; the box's own app answers (v7: whichever role it is;
  Alnasl only when its service is on, as in v6); with a screen, the kiosk painted.
  """
  def health do
    m1 = if answers("http://127.0.0.1:4041/healthz"), do: [], else: ["the setup server"]
    role = box_role()
    {name, port} = @role_app[role]

    m2 =
      cond do
        role == "arkab" ->
          port = Map.get(kv_file("/etc/arkab/arkab.env"), "ARKAB_PORT", "4050")
          if answers("http://127.0.0.1:#{port}/unlock"), do: [], else: ["Arkab"]

        enabled("#{role}.service") and not answers("http://127.0.0.1:#{port}/") ->
          [name]

        true ->
          []
      end

    m3 =
      if enabled("alnasl-kiosk.service") and display_connected() and not Sys.exists?(@painted),
        do: ["the screen"],
        else: []

    missing = m1 ++ m2 ++ m3
    {missing == [], Enum.join(missing, ", ")}
  end

  # v7.1: a trial boot that did not become healthy leaves the full diagnostics on the boot partition
  # (alnasl-trial-<version>-boot<N>.txt), so a box whose screen shows nothing can still say why: take the
  # card out, read it on any PC. No network, no remote access; the same report as Menu > Diagnostics > Save.
  # The report itself is AlnaslSetup.Diag's (collect/3, journals/0, report_text/3 with the header as an
  # ordered list of {key, value}, save_report/1 returning the file name on the boot partition).
  defp trial_report(version, boot, missing) do
    diag = AlnaslSetup.Diag

    unless Code.ensure_loaded?(diag) and function_exported?(diag, :report_text, 3) do
      raise "AlnaslSetup.Diag is not in this release"
    end

    info = apply(diag, :collect, [%{}, "", %{}])

    header = [
      {"slot", current_slot()},
      {"version", version},
      {"trial boot", "#{boot} of #{@tries}"},
      {"missing", if(missing == "", do: "?", else: missing)}
    ]

    text = apply(diag, :report_text, [info, apply(diag, :journals, []), header])
    name = apply(diag, :save_report, [text])
    clean = String.replace(version, ~r/[^0-9A-Za-z.]/, "")
    final = Path.join(@boot_efi, "alnasl-trial-#{if clean == "", do: "x", else: clean}-boot#{boot}.txt")
    File.rename!(Sys.path(Path.join(@boot_efi, name)), Sys.path(final))
    sync()
    log("diagnostics of this trial boot saved to #{final}")
  rescue
    # a report must never stop the reboot that gives the box its next try
    e -> log("could not save the diagnostics of this trial boot: #{inspect(e)}")
  catch
    kind, e -> log("could not save the diagnostics of this trial boot: #{Exception.format_banner(kind, e)}")
  end

  defp cmd_boot_check do
    case catching(fn -> read_env() end) do
      {:err, :os, _, m} ->
        log("no A/B boot environment: #{m}")
        0

      {:ok, env} ->
        boot_check(env)
    end
  end

  defp boot_check(env) do
    cur = current_slot()
    {train, version} = release()
    save_status(%{"phase" => "idle", "progress" => nil, "slot" => cur, "train" => train, "version" => version})
    tr = env_get(env, "alnasl_try")
    tv = env_get(env, "alnasl_try_version")
    tv = if tv in [nil, ""], do: "?", else: tv

    cond do
      not none?(env_get(env, "alnasl_failed")) ->
        record(
          "rolled_back",
          "the update to #{tv} did not start properly #{@tries} times; back on #{version} (slot #{cur})",
          version: tv
        )

        env
        |> env_put(
          alnasl_failed: "none",
          alnasl_try: "none",
          alnasl_tries: "0",
          alnasl_try_version: "",
          alnasl_slot: cur
        )
        |> write_env()

        save_status(%{"staged" => nil})
        if Sys.exists?(@trial), do: File.rm!(Sys.path(@trial))
        splash(["--set", "update-rolledback"])
        sleep(20)
        splash(["--set", "clear"])
        0

      not none?(tr) and tr != cur ->
        # The new slot was asked for and this is the old one: grub could not even find it.
        record("rolled_back", "slot #{tr} (#{tv}) could not be started; back on #{version}", version: tv)

        env
        |> env_put(alnasl_try: "none", alnasl_tries: "0", alnasl_try_version: "", alnasl_slot: cur)
        |> write_env()

        0

      none?(tr) ->
        if env_get(env, "alnasl_slot") != cur do
          log("grub's good slot was #{py_str(env_get(env, "alnasl_slot"))} but #{cur} runs; corrected")
          env |> env_put(alnasl_slot: cur) |> write_env()
        end

        0

      true ->
        trial_boot(env, cur, train, version)
    end
  end

  # A trial boot of this slot.
  defp trial_boot(env, cur, train, version) do
    t = load_json(@trial)
    boots = to_int(Map.get(t, "boots", 0)) + 1
    t = Map.put(t, "boots", boots)
    write_atomic(@trial, ordered_json(trial_pairs(t)) <> "\n")
    left = env_get(env, "alnasl_tries") || "?"

    if left == Integer.to_string(@tries),
      do: log("grub did not count this boot down (save_env failed?); counting here instead")

    log(
      "trial boot #{boots} of #{train} #{version} (grub tries left: #{left}); waiting up to #{@health_minutes} min for it to be healthy"
    )

    start = monotonic()
    deadline = start + @health_minutes * 60
    {ok, missing} = health_wait(start, deadline, health(), false)
    env = read_env()

    if ok do
      env
      |> env_put(alnasl_slot: cur, alnasl_try: "none", alnasl_tries: "0", alnasl_try_version: "", alnasl_failed: "none")
      |> write_env()

      if Sys.exists?(@trial), do: File.rm!(Sys.path(@trial))
      save_status(%{"staged" => nil})
      record("ok", "updated to #{train} #{version} (slot #{cur}); it started properly", version: version)
      0
    else
      if env_get(env, "alnasl_tries") == "0" or boots >= @tries do
        # Last try used up: go back now, without waiting for grub to notice.
        env
        |> env_put(alnasl_try: "none", alnasl_tries: "0", alnasl_failed: cur, alnasl_slot: other(cur))
        |> write_env()

        log("#{version} did not become healthy (#{missing}) in #{boots} boots; going back to slot #{other(cur)}")
      else
        log(
          "#{version} not healthy after #{trunc((monotonic() - start) / 60)} min (#{missing}); restarting for another try"
        )
      end

      save_status(%{"last_trial_note" => "boot #{boots}: missing #{missing}"})
      trial_report(version, boots, missing)
      splash(["--set", "reboot"])
      sync()
      run(["systemctl", "reboot"])
      1
    end
  end

  defp health_wait(_start, _deadline, {true, _} = res, _extended), do: res

  defp health_wait(start, deadline, {false, missing} = res, extended) do
    n = monotonic()

    cond do
      n >= deadline and not (n - start < @health_max_minutes * 60 and kiosk_loading()) ->
        res

      true ->
        # v7.1: a reboot in the middle of loading the new kiosk image throws that work away and starts it
        # again on the next try; on a slow card all three tries ran out like that (docs/v7-blackscreen.md).
        # While the load is still running, wait for it, up to HEALTH_MAX_MINUTES in all.
        extended =
          if n >= deadline and not extended do
            log(
              "not healthy after #{@health_minutes} min (#{missing}), but the kiosk image is still loading; waiting for it, up to #{@health_max_minutes} min"
            )

            true
          else
            extended
          end

        sleep(10)
        health_wait(start, deadline, health(), extended)
    end
  end

  # ------------------------------------------------------------------- status --

  @doc """
  The status as --status prints it (the setup server's /api/system), string keys: status.json with
  train, version, slot, ab, trial, updates_on, off_reason, index_url, default_index_url and busy.
  """
  def status do
    s = load_json(@status)

    {t, v} =
      case catching(&release/0) do
        {:ok, tv} -> tv
        _ -> {"?", "?"}
      end

    s = Map.merge(s, %{"train" => t, "version" => v})

    s =
      Map.put(
        s,
        "slot",
        case catching(&current_slot/0) do
          {:ok, slot} -> slot
          _ -> "?"
        end
      )

    s =
      case catching(fn -> read_env() end) do
        {:ok, env} ->
          tr = env_get(env, "alnasl_try")

          Map.merge(s, %{
            "ab" => true,
            "trial" =>
              if(none?(tr), do: nil, else: %{"slot" => tr, "version" => env_get(env, "alnasl_try_version") || ""})
          })

        _ ->
          Map.merge(s, %{"ab" => false, "trial" => nil})
      end

    {ok, why} = key_state()

    s =
      Map.merge(s, %{
        "updates_on" => ok,
        "off_reason" => why,
        "index_url" => index_url(),
        "default_index_url" => @default_index
      })

    busy = s["phase"] not in [nil, "idle", "staged"]

    # a run that died leaves its phase behind; the lock says whether one runs now
    busy =
      if busy do
        case flock(Sys.path(@lock), :nb) do
          {:ok, release} ->
            release.()
            s["phase"] == "restarting"

          _ ->
            busy
        end
      else
        busy
      end

    Map.put(s, "busy", busy)
  end

  defp cmd_status do
    IO.puts(Json.encode(status()))
    0
  end

  @cmds ~w(--check --nightly --request --from-boot-file --boot-check --status)

  @doc "The program: `argv` without the program name. Returns the exit code."
  def main(argv) do
    File.mkdir_p!(Sys.path(@dir))

    case argv do
      [cmd] when cmd in @cmds ->
        run_cmd(cmd)

      _ ->
        IO.write(:stderr, @usage)
        2
    end
  end

  defp run_cmd(cmd) do
    case cmd do
      "--check" -> locked(&cmd_check/0)
      "--nightly" -> locked(&cmd_nightly/0)
      "--request" -> locked(&cmd_request/0)
      "--from-boot-file" -> locked(&cmd_boot_file/0)
      "--boot-check" -> cmd_boot_check()
      "--status" -> cmd_status()
    end
  catch
    # what Python left as a traceback: the error on stderr, exit 1
    :throw, {:sysupd, :refused, m} ->
      IO.puts(:stderr, "Refused: " <> m)
      1

    :throw, {:sysupd, _, type, m} ->
      IO.puts(:stderr, "#{type}: #{m}")
      1

    kind, reason ->
      IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
      1
  end
end
