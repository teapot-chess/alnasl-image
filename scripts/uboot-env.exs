# v6 boot screen, the u-boot part. Run by bootscreen.sh on the build VM, inside the Elixir image
# (docker run ... elixir uboot-env.exs BOOTDIR), on a staging copy of the boot partition's files:
#
#     elixir uboot-env.exs BOOTDIR       (BOOTDIR holds u-boot-rpi4.bin and maybe uboot.env)
#
# u-boot: bootdelay=0 and its console on the serial port only (nothing on HDMI), written to
# uboot.env. The environment is u-boot's own default one (read out of u-boot-rpi4.bin) or the
# uboot.env already there, with those keys changed; if neither can be read with certainty, nothing
# is written and u-boot keeps its defaults. A uboot.env of the wrong size is ignored by u-boot ("bad
# CRC, using default environment"), so the worst case of a wrong guess is the v5 behaviour.
#
# This is the one piece of the boot screen that needs a real language (a CRC32 over a binary block
# and a scan of a binary); the grub part is plain shell in bootscreen.sh.
defmodule UbootEnv do
  # CONFIG_ENV_SIZE of the Raspberry Pi defconfigs
  @env_size 0x4000
  @set [{"bootdelay", "0"}, {"stdout", "serial"}, {"stderr", "serial"}, {"silent", "1"}]
  @entry ~r/^[A-Za-z0-9_#.:-]{1,64}=[\x09\x20-\x7e]*$/

  def say(msg), do: IO.puts("bootscreen: " <> msg)

  def entry?(e), do: Regex.match?(@entry, e)

  # NUL-separated key=value entries from start to the double NUL; nil if anything is off.
  def parse_block(data, start) do
    case :binary.match(data, <<0, 0>>, scope: {start, byte_size(data) - start}) do
      :nomatch ->
        nil

      {stop, _} ->
        entries = :binary.split(binary_part(data, start, stop - start), <<0>>, [:global])
        if Enum.all?(entries, &entry?/1), do: entries, else: nil
    end
  end

  # Index of the last NUL strictly before limit (python's rfind(b"\0", 0, limit)); -1 if none.
  def rfind_nul(_bin, limit) when limit <= 0, do: -1

  def rfind_nul(bin, limit) do
    case :binary.matches(binary_part(bin, 0, limit), <<0>>) do
      [] -> -1
      list -> list |> List.last() |> elem(0)
    end
  end

  # Walk back over whole entries while they look like entries.
  def walk_back(binary, start) do
    j = rfind_nul(binary, start - 1)
    cand = if start - 1 <= 0, do: "", else: binary_part(binary, j + 1, start - 1 - (j + 1))

    if start - 1 <= 0 or cand == "" or not entry?(cand),
      do: start,
      else: walk_back(binary, j + 1)
  end

  def default_env(binary) do
    best =
      :binary.matches(binary, "bootcmd=")
      |> Enum.reduce(nil, fn {i, _}, best ->
        # inside another string
        if i > 0 and :binary.at(binary, i - 1) != 0 do
          best
        else
          entries = parse_block(binary, walk_back(binary, i))
          if entries && (best == nil or length(entries) > length(best)), do: entries, else: best
        end
      end)

    keys = if best, do: MapSet.new(best, fn e -> hd(:binary.split(e, "=")) end), else: nil

    if best && length(best) >= 10 && MapSet.member?(keys, "bootcmd") &&
         MapSet.member?(keys, "boot_targets"),
       do: best,
       else: nil
  end

  # An ordered key=value list: an existing key keeps its place, a new one goes last (like a dict).
  def put(env, k, v) do
    if List.keymember?(env, k, 0),
      do: List.keyreplace(env, k, 0, {k, v}),
      else: env ++ [{k, v}]
  end

  def run(boot) do
    envp = Path.join(boot, "uboot.env")
    {entries, size, src} = existing(envp)

    {entries, src} =
      if entries == nil do
        ub = Path.join(boot, "u-boot-rpi4.bin")

        if File.regular?(ub),
          do: {default_env(File.read!(ub)), "u-boot-rpi4.bin's default environment"},
          else: {:missing, nil}
      else
        {entries, src}
      end

    cond do
      entries == :missing ->
        say("WARNING: u-boot: no u-boot-rpi4.bin; u-boot left with its defaults")

      entries == nil ->
        say("WARNING: u-boot: could not read its environment with certainty; u-boot left with its defaults")

      true ->
        write(envp, entries, size, src)
    end
  end

  defp existing(envp) do
    default = {nil, @env_size, nil}

    if File.regular?(envp) do
      raw = File.read!(envp)
      <<crc::little-32, rest::binary>> = if byte_size(raw) >= 4, do: raw, else: <<0::32>>

      if byte_size(raw) > 8 and crc == :erlang.crc32(rest) do
        {parse_block(raw, 4), byte_size(raw), "the uboot.env already there"}
      else
        say("u-boot: the uboot.env there has a bad CRC; it is replaced")
        default
      end
    else
      default
    end
  end

  defp write(envp, entries, size, src) do
    env =
      Enum.map(entries, fn e ->
        [k, v] = :binary.split(e, "=")
        {k, v}
      end)

    was = Map.new(@set, fn {k, _} -> {k, List.keyfind(env, k, 0)} end)
    env = Enum.reduce(@set, env, fn {k, v}, acc -> put(acc, k, v) end)
    body = IO.iodata_to_binary(Enum.map(env, fn {k, v} -> [k, "=", v, 0] end)) <> <<0>>

    if byte_size(body) > size - 4 do
      say("WARNING: u-boot: the environment does not fit in #{size} bytes; u-boot left with its defaults")
    else
      body = body <> :binary.copy(<<0>>, size - 4 - byte_size(body))
      File.write!(envp, <<:erlang.crc32(body)::little-32>> <> body)
      say("u-boot: uboot.env written from #{src} (#{length(env)} variables, #{size} bytes)")

      for {k, _} <- @set do
        old = case was[k], do: (nil -> "None"; {_, v} -> v)
        {_, new} = List.keyfind(env, k, 0)
        say("  #{k}: #{old} -> #{new}")
      end
    end
  end
end

case System.argv() do
  [boot] ->
    UbootEnv.run(boot)

  _ ->
    IO.puts(:stderr, "usage: elixir uboot-env.exs BOOTDIR")
    System.halt(1)
end
