defmodule AlnaslSetup.SystemUpdateTest do
  # Port of scripts/test-update.py (the train rule, the choice of image, the release index check, the grub
  # environment block, the roles, the signature check with a throw-away key), plus the files the updater
  # writes (status, history, last result, trial), the command lock, the downloads and the boot check.
  # Nothing here touches a disk, a partition or the network: a fake root, fake commands, a loopback server.
  use ExUnit.Case, async: false
  import Bitwise, only: [<<<: 2]

  alias AlnaslSetup.SystemUpdate, as: U
  alias AlnaslSetup.{Http, Json, Sys}
  alias AlnaslSetup.Test.Box

  @repo Path.expand("../..", __DIR__)
  @shipped_key Path.join(@repo, "overlay/etc/alnasl/update-key.pub")
  @grub_ab Path.join(@repo, "scripts/grub-ab.cfg")

  @env_head "# GRUB Environment Block\n"

  defp refused?(fun), do: match?({:refused, _}, U.attempt(fun))
  defp value_error?(fun), do: match?({:value_error, _}, U.attempt(fun))
  defp os_error?(fun), do: match?({:os_error, _}, U.attempt(fun))

  defp img(train, version, min_from \\ nil, kw \\ []) do
    Map.merge(
      %{
        "train" => train,
        "version" => version,
        "file" => "alnasl-system-v#{version}.img.zst",
        "url" => "https://example.invalid/#{version}.zst",
        "sig_url" => "https://example.invalid/#{version}.zst.sig",
        "size" => 1000,
        "raw_size" => 3000,
        "sha256" => String.duplicate("a", 64),
        "raw_sha256" => String.duplicate("b", 64),
        "min_from" => min_from
      },
      Map.new(kw, fn {k, v} -> {to_string(k), v} end)
    )
  end

  # The seams of this program (application environment :system_update): http (instead of the network),
  # sleep + monotonic (a fake clock), lock (instead of util-linux flock).
  defp seams!(kw) do
    Application.put_env(:alnasl_setup, :system_update, kw)
    on_exit(fn -> Application.delete_env(:alnasl_setup, :system_update) end)
  end

  defp fake_clock do
    {:ok, clock} = Agent.start_link(fn -> 0.0 end)
    [sleep: fn s -> Agent.update(clock, &(&1 + s)) end, monotonic: fn -> Agent.get(clock, & &1) end]
  end

  defp no_lock, do: [lock: fn _path, _mode -> {:ok, fn -> :ok end} end]

  defp grubenv(lines) do
    body = @env_head <> Enum.map_join(lines, "", &(&1 <> "\n"))
    String.pad_trailing(body, 1024, "#")
  end

  defp quiet(fun), do: ExUnit.CaptureIO.capture_io(fun)

  # ---- the train rule ------------------------------------------------------------------------------
  describe "train rule" do
    test "same train: allowed without asking", do: refute(refused?(fn -> U.train_guard(img("v6", "6.2"), "v6") end))
    test "next train, not asked: REFUSED", do: assert(refused?(fn -> U.train_guard(img("v7", "7.0"), "v6") end))

    test "next train, asked for exactly that train: allowed",
      do: refute(refused?(fn -> U.train_guard(img("v7", "7.0"), "v6", "v7") end))

    test "asked v7, image v8: REFUSED", do: assert(refused?(fn -> U.train_guard(img("v8", "8.0"), "v6", "v7") end))
    test "asked an OLDER train: REFUSED", do: assert(refused?(fn -> U.train_guard(img("v5", "5.9"), "v6", "v5") end))

    test "image whose version is of another train than it says: REFUSED",
      do: assert(refused?(fn -> U.train_guard(img("v6", "7.0"), "v6") end))

    test "the refusal says why" do
      assert {:refused, msg} = U.attempt(fn -> U.train_guard(img("v7", "7.0"), "v6") end)
      assert msg == "image 7.0 is of train v7; this box is on v6 and changes trains only when asked to (Upgrade to v7)"
    end
  end

  # ---- choosing ------------------------------------------------------------------------------------
  describe "choosing" do
    setup do
      %{idx: [img("v6", "6.0"), img("v6", "6.1"), img("v6", "6.2"), img("v7", "7.0", "6.2"), img("v7", "7.1", "6.2")]}
    end

    test "on 6.1: the newest of its own train (6.2); v7 not offered yet, it needs 6.2 first", %{idx: idx} do
      {best, up, blocked} = U.choose(idx, "v6", "6.1")
      assert best["version"] == "6.2"
      assert up == nil and blocked == "6.2"
    end

    test "on 6.2: nothing newer in v6; v7 (7.1) OFFERED, never chosen as best", %{idx: idx} do
      {best, up, _} = U.choose(idx, "v6", "6.2")
      assert best == nil
      assert up["train"] == "v7" and up["version"] == "7.1"
    end

    test "versions compare as numbers (6.10 > 6.2)", %{idx: idx} do
      {best, _, _} = U.choose(idx ++ [img("v6", "6.10")], "v6", "6.2")
      assert best["version"] == "6.10"
    end

    test "on 6.1, every newer v6 needs 6.2 or 6.3 first: nothing to take" do
      {best, _, _} = U.choose([img("v6", "6.3", "6.2"), img("v6", "6.4", "6.3")], "v6", "6.1")
      assert best == nil
    end

    test "a stepping stone is taken first (6.3 before 6.4 that needs it)" do
      {best, _, _} = U.choose([img("v6", "6.3"), img("v6", "6.4", "6.3")], "v6", "6.2")
      assert best["version"] == "6.3"
    end

    test "a box on v7 never goes back to v6", %{idx: idx} do
      {best, up, _} = U.choose(idx, "v7", "7.0")
      assert best["version"] == "7.1" and up == nil
    end
  end

  # ---- v7.0 as released: min_from 6.2, beside 6.1 and 6.2 (docs/v7-plan.md, "Version") ----------------
  describe "v7.0 as released" do
    setup do: %{idx7: [img("v6", "6.1"), img("v6", "6.2"), img("v7", "7.0", "6.2")]}

    test "a 6.2 box: 7.0 offered, nothing to install by itself; never unasked, allowed when asked", %{idx7: idx7} do
      {best, up, _} = U.choose(idx7, "v6", "6.2")
      assert best == nil and up["version"] == "7.0"
      assert refused?(fn -> U.train_guard(up, "v6") end)
      refute refused?(fn -> U.train_guard(up, "v6", "v7") end)
    end

    test "a 6.1 box: 6.2 first, v7 waits for it", %{idx7: idx7} do
      {best, up, blocked} = U.choose(idx7, "v6", "6.1")
      assert best["version"] == "6.2" and up == nil and blocked == "6.2"
    end
  end

  # ---- the release index ---------------------------------------------------------------------------
  describe "release index" do
    test "only the complete, consistent, https-only entry survives" do
      good = img("v6", "6.3")

      bad = [
        img("v6", "7.0"),
        img("v6", "6.4", nil, url: "http://example.invalid/x.zst"),
        img("v6", "6.5", nil, sha256: "xyz"),
        img("v6", "6.6", nil, size: 10 <<< 30),
        img("v6", "6.7", nil, file: "../evil.zst"),
        img("v6", "6.8", "six")
      ]

      quiet(fn ->
        got = U.parse_index(Json.encode(%{"format" => 1, "images" => [good | bad]}))
        assert Enum.map(got, & &1["version"]) == ["6.3"]
      end)
    end

    test "an unknown format is refused" do
      assert refused?(fn -> U.parse_index(~s({"format": 2, "images": []})) end)
    end

    test "not JSON at all is a ValueError (the check reports it as one)" do
      assert value_error?(fn -> U.parse_index("nope") end)
    end
  end

  # ---- versions ------------------------------------------------------------------------------------
  describe "versions" do
    test "version order" do
      assert U.vkey("6.10") > U.vkey("6.9") and U.vkey("6.2.1") > U.vkey("6.2")
      assert U.vkey("6.2") == {6, 2, 0}
    end

    test "bad version / train rejected" do
      assert value_error?(fn -> U.vkey("6.x") end)
      assert value_error?(fn -> U.train_no("6") end)
      assert U.train_no("v7") == 7
    end
  end

  # ---- grub environment block ----------------------------------------------------------------------
  describe "grubenv" do
    setup do
      dir = Path.join(System.tmp_dir!(), "alnasl-test-update-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Path.join(dir, "grubenv")
      File.write!(path, grubenv(["alnasl_slot=A", "alnasl_try=none", "alnasl_tries=0", "alnasl_failed=none"]))
      %{path: path}
    end

    test "read", %{path: path} do
      e = U.read_env(path)

      assert e == [
               {"alnasl_slot", "A"},
               {"alnasl_try", "none"},
               {"alnasl_tries", "0"},
               {"alnasl_failed", "none"}
             ]
    end

    test "written, still 1024 bytes, byte for byte, keys in place and new ones at the end", %{path: path} do
      e = U.read_env(path) |> U.env_put(alnasl_try: "B", alnasl_tries: "3", alnasl_try_version: "6.2")
      {:ok, ino} = File.stat(path)
      U.write_env(e, path)
      data = File.read!(path)
      assert byte_size(data) == 1024
      assert U.env_get(U.read_env(path), "alnasl_tries") == "3"

      assert data ==
               grubenv([
                 "alnasl_slot=A",
                 "alnasl_try=B",
                 "alnasl_tries=3",
                 "alnasl_failed=none",
                 "alnasl_try_version=6.2"
               ])

      # written in place (same file: grub's save_env needs its blocks)
      {:ok, ino2} = File.stat(path)
      assert match?({:win32, _}, :os.type()) or ino.inode == ino2.inode
    end

    test "a value with a newline is refused", %{path: path} do
      assert value_error?(fn -> U.write_env([{"alnasl_slot", "A\nalnasl_try=B"}], path) end)
    end

    test "an unsafe key, an empty key and a block over 1024 bytes are refused", %{path: path} do
      assert value_error?(fn -> U.write_env([{"alnasl slot", "A"}], path) end)
      assert value_error?(fn -> U.write_env([{"", "A"}], path) end)
      big = for i <- 1..20, do: {"k#{i}", String.duplicate("x", 60)}
      assert value_error?(fn -> U.write_env(big, path) end)
      assert byte_size(File.read!(path)) == 1024
    end

    test "a damaged block is not read as empty", %{path: path} do
      File.write!(path, String.duplicate("x", 100))
      assert os_error?(fn -> U.read_env(path) end)
    end

    test "a missing block is an OSError, never created", %{path: path} do
      File.rm!(path)
      assert os_error?(fn -> U.read_env(path) end)
      assert os_error?(fn -> U.write_env([{"alnasl_slot", "A"}], path) end)
      refute File.exists?(path)
    end
  end

  # ---- grub-ab.cfg: the counter the updater relies on --------------------------------------------------
  describe "grub-ab.cfg" do
    test "has every line the updater relies on, counting down from TRIES (3)" do
      cfg = File.read!(@grub_ab)

      for need <- [
            "load_env -f $alnasl_env",
            "save_env -f $alnasl_env alnasl_try alnasl_tries alnasl_failed",
            "set alnasl_tries=2",
            "set alnasl_tries=1",
            "set alnasl_tries=0",
            "set alnasl_failed=$alnasl_try",
            "root=PARTUUID=@DISKID@-$alnasl_part",
            "panic=10"
          ] do
        assert String.contains?(cfg, need), "grub-ab.cfg has: " <> need
      end

      assert U.tries() == 3 and String.contains?(cfg, ~s(if [ "$alnasl_tries" = "3" ]))
    end
  end

  # ---- v7 roles: what the box is decides what health and the round check look at ----------------------
  describe "roles" do
    setup do
      Box.root!()
      Box.runner!(fn _ -> nil end)
      :ok
    end

    test "role from the mode file" do
      for {word, role} <- [
            {"slave", "arkab"},
            {"master", "alnasl"},
            {"polis\n", "polis"},
            {"NUNKI", "nunki"},
            {"arkab", "arkab"},
            {"", "alnasl"},
            {"root", "alnasl"}
          ] do
        Box.put("/var/lib/alnasl-setup/mode", word)
        assert U.box_role() == role, "role from the mode file #{inspect(word)}: #{role}"
      end

      File.rm!(Sys.path("/var/lib/alnasl-setup/mode"))
      assert U.box_role() == "alnasl"
    end

    test "health of each box asks its own app and no other" do
      {:ok, asked} = Agent.start_link(fn -> [] end)
      seams!(http: fn url, _ -> Agent.update(asked, &[url | &1]) && {:ok, 200, ""} end)

      Box.runner!(fn
        ["systemctl", "is-enabled", _] -> {0, "enabled\n"}
        _ -> nil
      end)

      for {word, port} <- [{"polis", "4061"}, {"nunki", "4062"}, {"slave", "4050"}, {"master", "4040"}] do
        Box.put("/var/lib/alnasl-setup/mode", word)
        Agent.update(asked, fn _ -> [] end)
        {ok, _} = U.health()
        urls = Agent.get(asked, & &1)
        assert ok
        assert Enum.any?(urls, &String.contains?(&1, ":#{port}/"))

        for p <- ~w(4040 4050 4061 4062), p != port, u <- urls do
          refute String.contains?(u, ":#{p}/"), "health of a #{word} box asks #{u}"
        end
      end
    end

    test "a nunki box whose Nunki does not answer is not healthy" do
      seams!(http: fn url, _ -> if String.contains?(url, "4041"), do: {:ok, 200, ""}, else: {:error, :econnrefused} end)

      Box.runner!(fn
        ["systemctl", "is-enabled", _] -> {0, "enabled\n"}
        _ -> nil
      end)

      Box.put("/var/lib/alnasl-setup/mode", "nunki")
      assert U.health() == {false, "Nunki"}
    end

    test "an answer with an error status still counts as an answer" do
      seams!(http: fn _, _ -> {:ok, 503, ""} end)
      Box.runner!(fn _ -> {1, "disabled\n"} end)
      assert U.health() == {true, ""}
    end

    test "the screen counts when the kiosk is on and a display is connected" do
      seams!(http: fn _, _ -> {:ok, 200, ""} end)

      Box.runner!(fn
        ["systemctl", "is-enabled", _] -> {0, "enabled\n"}
        _ -> nil
      end)

      Box.put("/sys/class/drm/card1-HDMI-A-1/status", "connected\n")
      assert U.health() == {false, "the screen"}
      Box.put("/run/alnasl-kiosk/painted", "")
      assert U.health() == {true, ""}
    end

    test "no round check on a box without Alnasl" do
      Box.put("/var/lib/alnasl-setup/mode", "nunki")
      assert U.round_in_progress() == {false, "not an Alnasl box: no rounds here"}
    end

    test "the round check reads Alnasl's answer" do
      for {answer, want} <- [
            {{:ok, 200, ~s({"round_in_progress": true})}, {true, "round in progress"}},
            {{:ok, 200, ~s({"round_in_progress":false})}, {false, "no round in progress"}},
            {{:ok, 200, ~s({"x": 1})}, {false, "Alnasl gave no clear answer: treated as no round"}},
            {{:error, :econnrefused}, {false, "Alnasl not running or not answering: treated as no round"}},
            {{:ok, 500, ""}, {false, "Alnasl not running or not answering: treated as no round"}}
          ] do
        seams!(http: fn "http://127.0.0.1:4040/local/status", _ -> answer end)
        assert U.round_in_progress() == want
      end
    end

    test "carry-over knows all four apps" do
      assert Enum.sort(Map.keys(U.role_app())) == ["alnasl", "arkab", "nunki", "polis"]
    end
  end

  # ---- signatures ----------------------------------------------------------------------------------
  describe "signatures" do
    setup do
      Box.root!()
      :ok
    end

    test "the shipped key file holds no private key, and says whether updates are on" do
      ph = File.read!(@shipped_key)
      refute String.contains?(ph, "PRIVATE KEY-----")
      Box.put("/etc/alnasl/update-key.pub", ph)
      {ok, why} = U.key_state()

      if String.contains?(ph, "ALNASL-PLACEHOLDER") do
        assert not ok and String.contains?(why, "placeholder")
      else
        assert ok and why == ""
      end
    end

    test "a placeholder key or no key switches updates off" do
      assert U.key_state() == {false, "no update key in this image (/etc/alnasl/update-key.pub)"}
      Box.put("/etc/alnasl/update-key.pub", "ALNASL-PLACEHOLDER\n")
      assert U.key_state() == {false, "this image carries the placeholder update key: system updates are off"}

      Box.put(
        "/etc/alnasl/update-key.pub",
        "-----BEGIN PUBLIC KEY-----\nALNASL-PLACEHOLDER\n-----END PUBLIC KEY-----\n"
      )

      assert elem(U.key_state(), 0) == false
    end

    test "verify_sig asks openssl exactly so and wants 'Verified OK'" do
      Box.runner!(fn
        ["openssl" | _] -> {0, "Verified OK\n"}
      end)

      refute refused?(fn -> U.verify_sig("/x/index.json", "/x/index.json.sig") end)

      assert [["openssl", "dgst", "-sha256", "-verify", key, "-signature", sig, file]] = Box.ran()
      assert key == Sys.path("/etc/alnasl/update-key.pub")
      assert sig == Sys.path("/x/index.json.sig") and file == Sys.path("/x/index.json")

      Box.runner!(fn ["openssl" | _] -> {0, "Verification failure\n"} end)
      assert {:refused, msg} = U.attempt(fn -> U.verify_sig("/x/index.json", "/x/index.json.sig") end)
      assert msg == "the signature of index.json does not match this image's update key"
      Box.runner!(fn ["openssl" | _] -> {1, "Verified OK\n"} end)
      assert refused?(fn -> U.verify_sig("/x/index.json", "/x/index.json.sig") end)
    end

    @tag :unix
    @tag :openssl
    test "with the openssl CLI: signed verifies, one byte changed or another key is REFUSED" do
      openssl = System.find_executable("openssl")

      if openssl do
        tmp = Sys.path("/tmp")
        File.mkdir_p!(tmp)
        ossl = fn args -> {_, 0} = System.cmd(openssl, args, stderr_to_stdout: true) end
        key = Path.join(tmp, "throwaway.key")
        pub = Path.join(tmp, "throwaway.pub")
        ossl.(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key])
        ossl.(["ec", "-in", key, "-pubout", "-out", pub])
        Box.put("/etc/alnasl/update-key.pub", File.read!(pub))
        assert elem(U.key_state(), 0), "a real public key switches updates on"

        data = Box.put("/tmp/index.json", Json.encode(%{"format" => 1, "images" => [img("v6", "6.3")]}))
        ossl.(["dgst", "-sha256", "-sign", key, "-out", data <> ".sig", data])
        refute refused?(fn -> U.verify_sig("/tmp/index.json", "/tmp/index.json.sig") end)

        File.write!(data, " ", [:append])
        assert refused?(fn -> U.verify_sig("/tmp/index.json", "/tmp/index.json.sig") end)

        key2 = Path.join(tmp, "other.key")
        ossl.(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key2])
        ossl.(["dgst", "-sha256", "-sign", key2, "-out", data <> ".sig", data])
        assert refused?(fn -> U.verify_sig("/tmp/index.json", "/tmp/index.json.sig") end)
      end
    end
  end

  # ---- the files it writes -------------------------------------------------------------------------
  describe "status and results" do
    setup do
      Box.root!()
      Box.runner!(fn _ -> nil end)
      :ok
    end

    test "status.json is json.dumps(indent=1, sort_keys=True) plus a newline, fields merged" do
      U.save_status(%{"phase" => "checking", "progress" => nil})

      s =
        U.save_status(%{
          "available" => %{"train" => "v6", "notes" => "é"},
          "offer" => nil,
          "list" => [1, 2],
          "e" => %{}
        })

      assert s["phase"] == "checking"
      text = File.read!(Sys.path("/var/lib/alnasl-os-update/system/status.json"))
      when_ = s["updated_at"]

      assert text ==
               ~s({\n "available": {\n  "notes": "\\u00e9",\n  "train": "v6"\n },\n "e": {},\n "list": [\n  1,\n  2\n ],\n) <>
                 ~s( "offer": null,\n "phase": "checking",\n "progress": null,\n "updated_at": "#{when_}"\n}\n)

      assert Regex.match?(~r/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}$/, when_)
    end

    test "record: last result, history line, status, journal line" do
      out =
        quiet(fn -> U.record("staged", "v6 6.3 written to slot B and checked", version: "6.3", by: "menu") end)

      assert out =~ "alnasl-system-update: staged: v6 6.3 written to slot B and checked\n"
      last = File.read!(Sys.path("/var/lib/alnasl-os-update/system-last-result"))
      [l1, l2, l3, l4, l5] = String.split(last, "\n", trim: true)
      assert l1 =~ ~r/^when:     \d{4}-/
      assert l2 == "outcome:  staged"
      assert l3 == "note:     v6 6.3 written to slot B and checked"
      assert l4 == "version:  6.3"
      assert l5 == "by:       menu"
      hist = File.read!(Sys.path("/var/lib/alnasl-os-update/system-history"))
      assert hist =~ ~r/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4}  staged  v6 6.3 written to slot B and checked\n$/
      s = Json.decode_or_nil(File.read!(Sys.path("/var/lib/alnasl-os-update/system/status.json")))
      assert s["last_result"]["outcome"] == "staged" and s["last_result"]["by"] == "menu"
    end

    test "the history keeps its last 60 lines" do
      Box.put("/var/lib/alnasl-os-update/system-history", Enum.map_join(1..70, "", &"old #{&1}\n"))
      quiet(fn -> U.record("nothing", "n") end)
      lines = String.split(File.read!(Sys.path("/var/lib/alnasl-os-update/system-history")), "\n", trim: true)
      assert length(lines) == 60
      assert hd(lines) == "old 12"
      assert List.last(lines) =~ "  nothing  n"
    end

    test "status/0 is what --status prints, and says whether a run is really busy" do
      seams!(no_lock())
      Box.put("/etc/alnasl/image-release", "ALNASL_TRAIN=v6\nALNASL_VERSION=\"6.2\"\n")
      Box.put("/etc/alnasl/update-key.pub", File.read!(@shipped_key))
      Box.put("/boot/efi/alnasl/grubenv", grubenv(["alnasl_slot=A", "alnasl_try=B", "alnasl_try_version=6.3"]))
      Box.put("/var/lib/alnasl-os-update/system/status.json", ~s({"phase": "downloading", "progress": 40}))

      s = U.status()
      assert s["train"] == "v6" and s["version"] == "6.2"
      assert s["slot"] == "?"
      assert s["ab"] == true
      assert s["trial"] == %{"slot" => "B", "version" => "6.3"}
      assert s["updates_on"] == true and s["off_reason"] == ""
      assert s["index_url"] == "https://github.com/teapot-chess/alnasl-image/releases/download/index/index.json"
      assert s["default_index_url"] == s["index_url"]
      assert s["progress"] == 40
      # the phase says downloading, but nobody holds the lock: a run that died
      assert s["busy"] == false

      seams!(lock: fn _, :nb -> :busy end)
      assert U.status()["busy"] == true

      out = quiet(fn -> assert U.main(["--status"]) == 0 end)
      assert Json.decode_or_nil(String.trim(out)) == U.status()
      assert out == Json.encode(U.status()) <> "\n"
    end

    test "status without A/B, with a bad release file, with an index URL of its own" do
      seams!(no_lock())
      Box.put("/var/lib/alnasl-setup/state.json", ~s({"update_url": "https://mirror.example/index.json"}))
      s = U.status()
      assert s["ab"] == false and s["trial"] == nil
      assert s["train"] == "?" and s["version"] == "?"
      assert s["busy"] == false
      assert s["index_url"] == "https://mirror.example/index.json"
      assert s["updates_on"] == false

      Box.put("/var/lib/alnasl-setup/state.json", ~s({"update_url": "http://mirror.example/index.json"}))
      Box.put("/etc/alnasl/update.conf", "INDEX_URL=\"https://conf.example/i.json\"\n")
      assert U.status()["index_url"] == "https://conf.example/i.json"
    end

    test "a status that says restarting stays busy without a lock holder" do
      seams!(no_lock())
      Box.put("/var/lib/alnasl-os-update/system/status.json", ~s({"phase": "restarting"}))
      assert U.status()["busy"] == true
      Box.put("/var/lib/alnasl-os-update/system/status.json", ~s({"phase": "staged"}))
      assert U.status()["busy"] == false
    end
  end

  # ---- commands ------------------------------------------------------------------------------------
  describe "commands" do
    setup do
      Box.root!()
      Box.runner!(fn _ -> nil end)
      :ok
    end

    test "usage: anything else is exit 2 with the help on stderr" do
      err = ExUnit.CaptureIO.capture_io(:stderr, fn -> assert U.main([]) == 2 end)
      assert err =~ "alnasl-system-update --check"
      ExUnit.CaptureIO.capture_io(:stderr, fn -> assert U.main(["--check", "x"]) == 2 end)
      ExUnit.CaptureIO.capture_io(:stderr, fn -> assert U.main(["--bogus"]) == 2 end)
    end

    test "a busy lock stops every locked command with exit 4" do
      seams!(lock: fn _, :nb -> :busy end)

      for cmd <- ~w(--check --nightly --request --from-boot-file) do
        out = quiet(fn -> assert U.main([cmd]) == 4 end)
        assert out == "alnasl-system-update: another run is busy; this one stops\n"
      end
    end

    test "--check with the placeholder key: no index read, the reason in the status" do
      seams!(no_lock() ++ [http: fn _, _ -> flunk("no network without a key") end])
      Box.put("/etc/alnasl/image-release", "ALNASL_TRAIN=v6\nALNASL_VERSION=6.2\n")
      Box.put("/etc/alnasl/update-key.pub", "ALNASL-PLACEHOLDER\n")
      out = quiet(fn -> assert U.main(["--check"]) == 0 end)
      assert out =~ "check: this image carries the placeholder update key: system updates are off"
      s = U.status()
      assert s["phase"] == "idle" and s["check_error"] =~ "placeholder"
    end

    test "--check: the index is fetched, signature checked, the choice in the status" do
      idx = Json.encode(%{"format" => 1, "images" => [img("v6", "6.3"), img("v7", "7.0", "6.3")]})

      seams!(
        no_lock() ++
          [
            http: fn
              "https://github.com/teapot-chess/alnasl-image/releases/download/index/index.json", _ ->
                {:ok, 200, idx}

              "https://github.com/teapot-chess/alnasl-image/releases/download/index/index.json.sig", _ ->
                {:ok, 200, "SIG"}
            end
          ]
      )

      Box.runner!(fn ["openssl" | _] -> {0, "Verified OK\n"} end)
      Box.put("/etc/alnasl/image-release", "ALNASL_TRAIN=v6\nALNASL_VERSION=6.2\n")
      Box.put("/etc/alnasl/update-key.pub", File.read!(@shipped_key))
      out = quiet(fn -> assert U.main(["--check"]) == 0 end)
      assert out =~ "alnasl-system-update: check: on v6 6.2; this train: 6.3; later train: none (needs 6.3 first)\n"
      s = U.status()
      assert s["available"]["version"] == "6.3" and s["available"]["size"] == 1000
      assert s["available"]["released"] == "" and s["available"]["notes"] == ""
      assert s["offer"] == nil and s["offer_blocked"] == "6.3" and s["check_error"] == nil
      assert File.read!(Sys.path("/var/lib/alnasl-os-update/system/download/index.json.sig")) == "SIG"
    end

    test "--check: a bad signature is the check error" do
      seams!(no_lock() ++ [http: fn _, _ -> {:ok, 200, ~s({"format": 1, "images": []})} end])
      Box.runner!(fn ["openssl" | _] -> {1, "Verification failure\n"} end)
      Box.put("/etc/alnasl/image-release", "ALNASL_TRAIN=v6\nALNASL_VERSION=6.2\n")
      Box.put("/etc/alnasl/update-key.pub", File.read!(@shipped_key))
      quiet(fn -> assert U.main(["--check"]) == 0 end)
      assert U.status()["check_error"] == "the signature of index.json does not match this image's update key"
    end

    test "--check: a network error names its kind" do
      seams!(no_lock() ++ [http: fn _, _ -> {:ok, 404, "nope"} end])
      Box.put("/etc/alnasl/image-release", "ALNASL_TRAIN=v6\nALNASL_VERSION=6.2\n")
      Box.put("/etc/alnasl/update-key.pub", File.read!(@shipped_key))
      quiet(fn -> assert U.main(["--check"]) == 0 end)
      assert U.status()["check_error"] == "could not read the release index (HTTPError)"
    end

    test "--request: a round in progress changes nothing" do
      seams!(
        no_lock() ++
          [http: fn "http://127.0.0.1:4040/local/status", _ -> {:ok, 200, ~s({"round_in_progress": true})} end]
      )

      Box.put("/var/lib/alnasl-os-update/system/request", ~s({"action": "install", "by": "arkab"}))
      quiet(fn -> assert U.main(["--request"]) == 1 end)
      refute File.exists?(Sys.path("/var/lib/alnasl-os-update/system/request"))
      s = U.status()
      assert s["request_error"] == "round_in_progress"
      assert s["last_result"]["outcome"] == "skipped"
      assert s["last_result"]["note"] == "asked for by arkab, but a round is in progress; nothing changed"
    end

    test "--request: no request file is exit 0; a request not understood is removed" do
      seams!(no_lock())
      quiet(fn -> assert U.main(["--request"]) == 0 end)

      for bad <- [~s({"action": "reboot"}), ~s({"action": "upgrade", "train": "7"}), "nope", ~s(["install"])] do
        Box.put("/var/lib/alnasl-os-update/system/request", bad)
        out = quiet(fn -> assert U.main(["--request"]) == 0 end)
        assert out == "alnasl-system-update: the request was not understood; removed\n"
        refute File.exists?(Sys.path("/var/lib/alnasl-os-update/system/request"))
      end
    end

    test "take_request reads at most 400 characters" do
      Box.put("/var/lib/alnasl-os-update/system/request", ~s({"action": "install", "by": "menu"}))
      assert U.take_request() == %{"action" => "install", "by" => "menu"}

      Box.put(
        "/var/lib/alnasl-os-update/system/request",
        ~s({"action": "install", "by": ") <> String.duplicate("x", 500) <> ~s("})
      )

      quiet(fn -> assert U.take_request() == nil end)
    end

    test "--request upgrade: a train that is not in the index, or out of reach" do
      idx = Json.encode(%{"format" => 1, "images" => [img("v6", "6.3"), img("v7", "7.0", "6.3")]})

      seams!(
        no_lock() ++
          [
            http: fn
              "http://127.0.0.1:4040/" <> _, _ -> {:error, :econnrefused}
              "https://" <> _ = u, _ -> if String.ends_with?(u, ".sig"), do: {:ok, 200, "S"}, else: {:ok, 200, idx}
            end
          ]
      )

      Box.runner!(fn
        ["openssl" | _] -> {0, "Verified OK\n"}
        _ -> nil
      end)

      Box.put("/etc/alnasl/image-release", "ALNASL_TRAIN=v6\nALNASL_VERSION=6.2\n")
      Box.put("/etc/alnasl/update-key.pub", File.read!(@shipped_key))

      Box.put("/var/lib/alnasl-os-update/system/request", ~s({"action": "upgrade", "train": "v8", "by": "menu"}))
      quiet(fn -> assert U.main(["--request"]) == 1 end)
      assert U.status()["last_result"]["note"] == "asked for by menu: there is no image of train v8"

      Box.put("/var/lib/alnasl-os-update/system/request", ~s({"action": "upgrade", "train": "v7", "by": "menu"}))
      quiet(fn -> assert U.main(["--request"]) == 1 end)
      assert U.status()["last_result"]["note"] == "v7 needs at least (6, 3, 0) first; this box has 6.2"
    end

    test "--from-boot-file: consumed first; a word that is not a train is refused" do
      seams!(no_lock())
      quiet(fn -> assert U.main(["--from-boot-file"]) == 0 end)
      Box.put("/boot/efi/alnasl-upgrade.txt", "\uFEFFseven\r\n")
      quiet(fn -> assert U.main(["--from-boot-file"]) == 1 end)
      refute File.exists?(Sys.path("/boot/efi/alnasl-upgrade.txt"))

      assert U.status()["last_result"]["note"] ==
               "/boot/efi/alnasl-upgrade.txt did not name a train (like v7) on its first line; removed it"
    end

    test "--nightly without A/B: skipped, exit 0; with a trial on: exit 4" do
      seams!(no_lock())
      out = quiet(fn -> assert U.main(["--nightly"]) == 0 end)
      assert out =~ "alnasl-system-update: no A/B boot environment ("
      assert out =~ "); system updates skipped\n"
      Box.put("/boot/efi/alnasl/grubenv", grubenv(["alnasl_slot=A", "alnasl_try=B", "alnasl_tries=2"]))
      out = quiet(fn -> assert U.main(["--nightly"]) == 4 end)
      assert out == "alnasl-system-update: a new slot is on trial; nothing tonight\n"
    end
  end

  # ---- the boot check ------------------------------------------------------------------------------
  describe "boot check" do
    setup do
      Box.root!()
      Box.put("/etc/alnasl/image-release", "ALNASL_TRAIN=v6\nALNASL_VERSION=6.3\n")

      Box.runner!(fn
        ["systemctl", "is-enabled", _] -> {0, "enabled\n"}
        ["systemctl", "show" | _] -> {0, "inactive\n"}
        _ -> nil
      end)

      boot_seams(http: fn _, _ -> {:ok, 200, ""} end)
      :ok
    end

    # / on partition 2 of mmcblk0: slot A
    defp boot_seams(kw), do: seams!(fake_clock() ++ [root_part: fn -> {"mmcblk0", "mmcblk0p2", 2} end] ++ kw)

    defp env_now, do: U.read_env(Sys.path("/boot/efi/alnasl/grubenv")) |> Map.new()

    test "runs on A, nothing on trial, grub's slot right: nothing changes" do
      Box.put("/boot/efi/alnasl/grubenv", grubenv(["alnasl_slot=A", "alnasl_try=none"]))
      before = File.read!(Sys.path("/boot/efi/alnasl/grubenv"))
      quiet(fn -> assert U.main(["--boot-check"]) == 0 end)
      assert File.read!(Sys.path("/boot/efi/alnasl/grubenv")) == before
      s = U.status()
      assert s["slot"] == "A" and s["train"] == "v6" and s["version"] == "6.3" and s["phase"] == "idle"
    end

    test "grub's good slot wrong: corrected" do
      Box.put("/boot/efi/alnasl/grubenv", grubenv(["alnasl_slot=B", "alnasl_try=none"]))
      out = quiet(fn -> assert U.main(["--boot-check"]) == 0 end)
      assert out =~ "grub's good slot was B but A runs; corrected"
      assert env_now()["alnasl_slot"] == "A"
    end

    test "grub gave up on the trial: rolled back, reported, env settled" do
      Box.put(
        "/boot/efi/alnasl/grubenv",
        grubenv(["alnasl_slot=A", "alnasl_try=none", "alnasl_tries=0", "alnasl_failed=B", "alnasl_try_version=6.4"])
      )

      Box.put("/var/lib/alnasl-os-update/system/trial.json", ~s({"slot": "B"}))
      quiet(fn -> assert U.main(["--boot-check"]) == 0 end)
      e = env_now()
      assert e["alnasl_failed"] == "none" and e["alnasl_try"] == "none" and e["alnasl_tries"] == "0"
      assert e["alnasl_try_version"] == "" and e["alnasl_slot"] == "A"
      refute File.exists?(Sys.path("/var/lib/alnasl-os-update/system/trial.json"))
      s = U.status()
      assert s["last_result"]["outcome"] == "rolled_back"
      assert s["last_result"]["note"] == "the update to 6.4 did not start properly 3 times; back on 6.3 (slot A)"
      assert s["last_result"]["version"] == "6.4"
      assert ["/usr/local/sbin/alnasl-splash", "--set", "update-rolledback"] in Box.ran()
      assert ["/usr/local/sbin/alnasl-splash", "--set", "clear"] in Box.ran()
    end

    test "the new slot was asked for but the old one runs: grub could not start it" do
      Box.put(
        "/boot/efi/alnasl/grubenv",
        grubenv(["alnasl_slot=A", "alnasl_try=B", "alnasl_tries=2", "alnasl_try_version=6.4"])
      )

      quiet(fn -> assert U.main(["--boot-check"]) == 0 end)
      assert U.status()["last_result"]["note"] == "slot B (6.4) could not be started; back on 6.3"
      e = env_now()
      assert e["alnasl_try"] == "none" and e["alnasl_slot"] == "A" and e["alnasl_tries"] == "0"
    end

    test "a trial boot that is healthy: marked good" do
      Box.put(
        "/boot/efi/alnasl/grubenv",
        grubenv(["alnasl_slot=B", "alnasl_try=A", "alnasl_tries=2", "alnasl_try_version=6.3"])
      )

      Box.put("/var/lib/alnasl-os-update/system/trial.json", ~s({"slot": "A", "version": "6.3", "boots": 0}))
      quiet(fn -> assert U.main(["--boot-check"]) == 0 end)
      e = env_now()
      assert e["alnasl_slot"] == "A" and e["alnasl_try"] == "none" and e["alnasl_failed"] == "none"
      refute File.exists?(Sys.path("/var/lib/alnasl-os-update/system/trial.json"))
      assert U.status()["last_result"]["note"] == "updated to v6 6.3 (slot A); it started properly"
      refute Enum.any?(Box.ran(), &match?(["systemctl", "reboot"], &1))
    end

    test "a trial boot never healthy, last try: gives up on the slot and restarts" do
      boot_seams(http: fn _, _ -> {:error, :econnrefused} end)

      Box.put(
        "/boot/efi/alnasl/grubenv",
        grubenv(["alnasl_slot=B", "alnasl_try=A", "alnasl_tries=0", "alnasl_try_version=6.3"])
      )

      Box.put("/var/lib/alnasl-os-update/system/trial.json", ~s({"slot": "A", "version": "6.3", "boots": 2}))
      out = quiet(fn -> assert U.main(["--boot-check"]) == 1 end)
      assert out =~ "trial boot 3 of v6 6.3 (grub tries left: 0); waiting up to 15 min for it to be healthy"
      assert out =~ "6.3 did not become healthy (the setup server, Alnasl) in 3 boots; going back to slot B"
      e = env_now()
      assert e["alnasl_failed"] == "A" and e["alnasl_slot"] == "B" and e["alnasl_try"] == "none"
      assert Json.decode_or_nil(File.read!(Sys.path("/var/lib/alnasl-os-update/system/trial.json")))["boots"] == 3
      assert U.status()["last_trial_note"] == "boot 3: missing the setup server, Alnasl"
      assert List.last(Box.ran()) == ["systemctl", "reboot"]
      assert ["/usr/local/sbin/alnasl-splash", "--set", "reboot"] in Box.ran()
    end

    test "a trial boot not healthy yet with tries left: another try" do
      boot_seams(http: fn _, _ -> {:error, :econnrefused} end)

      Box.put(
        "/boot/efi/alnasl/grubenv",
        grubenv(["alnasl_slot=B", "alnasl_try=A", "alnasl_tries=2", "alnasl_try_version=6.3"])
      )

      out = quiet(fn -> assert U.main(["--boot-check"]) == 1 end)
      assert out =~ "6.3 not healthy after 15 min (the setup server, Alnasl); restarting for another try"
      assert env_now()["alnasl_try"] == "A"
      assert List.last(Box.ran()) == ["systemctl", "reboot"]
    end

    test "while the kiosk image still loads, the trial waits longer (up to 60 min)" do
      boot_seams(http: fn _, _ -> {:error, :econnrefused} end)

      Box.runner!(fn
        ["systemctl", "show" | _] -> {0, "activating\n"}
        _ -> nil
      end)

      Box.put(
        "/boot/efi/alnasl/grubenv",
        grubenv(["alnasl_slot=B", "alnasl_try=A", "alnasl_tries=2", "alnasl_try_version=6.3"])
      )

      out = quiet(fn -> assert U.main(["--boot-check"]) == 1 end)
      assert out =~ "but the kiosk image is still loading; waiting for it, up to 60 min"
      assert out =~ "not healthy after 60 min"
    end
  end

  # ---- the card ------------------------------------------------------------------------------------
  describe "the card" do
    setup do
      Box.root!()
      seams!(root_part: fn -> {"mmcblk0", "mmcblk0p2", 2} end)
      Box.put("/sys/class/block/mmcblk0/mmcblk0p1/partition", "1\n")
      Box.put("/sys/class/block/mmcblk0/mmcblk0p2/partition", "2\n")
      Box.put("/sys/class/block/mmcblk0/mmcblk0p3/partition", "3\n")
      Box.put("/sys/class/block/mmcblk0/mmcblk0p3/size", "8\n")
      Box.put("/dev/mmcblk0p3", String.duplicate(<<0>>, 4096))
      Box.runner!(fn ["blkid" | _] -> {0, "416c6e73-03\n"} end)
      :ok
    end

    test "the current slot is the partition / is on; the target is the other partition" do
      assert U.current_slot() == "A"
      assert U.target_device("B") == {"/dev/mmcblk0p3", 4096}
    end

    test "the running slot, a mounted target and another disk's partition are refused" do
      assert U.attempt(fn -> U.target_device("A") end) == {:refused, "the target slot is the running one"}
      Box.put("/proc/self/mountinfo", "36 25 179:3 / /mnt rw - ext4 /dev/mmcblk0p3 rw\n")
      assert U.attempt(fn -> U.target_device("B") end) == {:refused, "/dev/mmcblk0p3 is mounted"}
      File.rm!(Sys.path("/proc/self/mountinfo"))
      Box.runner!(fn ["blkid" | _] -> {0, "deadbeef-03\n"} end)

      assert U.attempt(fn -> U.target_device("B") end) ==
               {:refused, "/dev/mmcblk0p3 belongs to another disk layout (deadbeef-03)"}
    end

    test "a card without the v6 layout, and / not on a system slot" do
      File.rm_rf!(Sys.path("/sys/class/block/mmcblk0/mmcblk0p3"))

      assert U.attempt(fn -> U.target_device("B") end) ==
               {:refused, "partition 3 of mmcblk0 not found: this card does not have the v6 layout"}

      seams!(root_part: fn -> {"mmcblk0", "mmcblk0p4", 4} end)
      assert U.attempt(fn -> U.current_slot() end) == {:refused, "/ is on partition 4, not on a system slot (2 or 3)"}
    end

    test "the kernel command line disagreeing: the partition wins" do
      Box.put("/proc/cmdline", "root=PARTUUID=416c6e73-02 alnasl.slot=B quiet\n")
      out = quiet(fn -> assert U.current_slot() == "A" end)
      assert out == "alnasl-system-update: cmdline says slot B, / is on partition 2: trusting the partition\n"
    end

    @tag :unix
    test "root_part reads sysfs the way the box has it" do
      Application.delete_env(:alnasl_setup, :system_update)
      sys = U.root_sysfs()
      # st_dev as coreutils' stat sees it, taken apart the way glibc's major() and minor() do
      {dev, 0} = System.cmd("stat", ["-c", "%d", Sys.path("/")])
      dev = String.to_integer(String.trim(dev))
      maj = Bitwise.bor(Bitwise.band(Bitwise.bsr(dev, 8), 0xFFF), Bitwise.band(Bitwise.bsr(dev, 32), 0xFFFFF000))
      min = Bitwise.bor(Bitwise.band(dev, 0xFF), Bitwise.band(Bitwise.bsr(dev, 12), 0xFFFFFF00))
      assert sys == "/sys/dev/block/#{maj}:#{min}"
      tail = "devices/platform/emmc2/mmc_host/mmc0/mmc0:0001/block/mmcblk0/mmcblk0p2"
      Box.put("/sys/" <> tail <> "/partition", "2\n")
      File.mkdir_p!(Path.dirname(Sys.path(sys)))
      # /sys/dev/block/M:m -> ../../devices/...
      :ok = File.ln_s("../../" <> tail, Sys.path(sys))
      assert U.root_part() == {"mmcblk0", "mmcblk0p2", 2}
      assert U.current_slot() == "A"
    end
  end

  # ---- downloads (a loopback server; the https-only rule applies to redirects) --------------------------
  describe "downloads" do
    setup do
      Box.root!()
      Box.runner!(fn _ -> nil end)
      body = :binary.copy("0123456789", 100)

      handler = fn
        %{path: "/img", headers: %{"range" => "bytes=" <> from}} ->
          from = String.to_integer(String.trim_trailing(from, "-"))
          {206, [{"Content-Range", "bytes #{from}-999/1000"}], binary_part(body, from, 1000 - from)}

        %{path: "/img"} = r ->
          {200, [{"X-UA", r.headers["user-agent"] || ""}], body}

        %{path: "/to-http"} ->
          {302, [{"Location", "http://127.0.0.1:1/img"}], ""}

        %{path: "/big"} ->
          {200, [], body}

        _ ->
          {404, [], "no"}
      end

      id = {:sysupd_test, System.unique_integer()}
      {:ok, pid} = Http.start_link(id: id, ip: {127, 0, 0, 1}, port: 0, handler: handler)
      on_exit(fn -> Process.exit(pid, :kill) end)
      %{base: "http://127.0.0.1:#{Http.port(id)}", body: body}
    end

    test "fetch: the body, within the limit", %{base: base, body: body} do
      assert U.fetch(base <> "/img", 1000) == body
      assert {:refused, msg} = U.attempt(fn -> U.fetch(base <> "/big", 999) end)
      assert msg == "#{base}/big is larger than 999 bytes"
    end

    test "fetch: an error status is an HTTPError", %{base: base} do
      assert {:url_error, "HTTPError: HTTP Error 404: Not Found"} = U.attempt(fn -> U.fetch(base <> "/nope", 100) end)
    end

    test "a redirect to plain http is never followed", %{base: base} do
      assert {:url_error, "HTTPError: HTTP Error 302: Found"} = U.attempt(fn -> U.fetch(base <> "/to-http", 100) end)
    end

    test "download: whole, then resumed from a partial file", %{base: base, body: body} do
      dest = "/var/lib/alnasl-os-update/system/download/alnasl-system-v6.3.img.zst"
      prog = U.progress_new("downloading", "update-download", true, false)
      U.download(base <> "/img", dest, 1000, prog)
      assert File.read!(Sys.path(dest)) == body
      refute File.exists?(Sys.path(dest <> ".part"))

      File.rm!(Sys.path(dest))
      Box.put(dest <> ".part", binary_part(body, 0, 400))
      U.download(base <> "/img", dest, 1000, prog)
      assert File.read!(Sys.path(dest)) == body
      assert U.status()["phase"] == "downloading" and U.status()["progress"] == 100
    end

    test "download: more than the index says is refused", %{base: base} do
      dest = "/var/lib/alnasl-os-update/system/download/x.zst"
      prog = U.progress_new("downloading", "update-download", true, false)

      assert {:refused, "the download is larger than the index says"} =
               U.attempt(fn -> U.download(base <> "/img", dest, 999, prog) end)
    end

    test "sha256_file streams the file" do
      p = Box.put("/x/f", "abc")
      assert U.sha256_file(p) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    end
  end

  # ---- the lock (util-linux flock) -----------------------------------------------------------------
  describe "lock" do
    @describetag :unix
    setup do
      Box.root!()
      :ok
    end

    test "non-blocking: a second holder is told busy; free again once released" do
      if System.find_executable("flock") do
        path = Sys.path("/run/alnasl-system-update.lock")
        assert {:ok, release} = U.flock(path, :nb)
        {:ok, st} = File.stat(path)
        assert Bitwise.band(st.mode, 0o777) == 0o600
        assert U.flock(path, :nb) == :busy
        release.()
        assert eventually(fn -> match?({:ok, _}, r = U.flock(path, :nb)) && (elem(r, 1).() || true) end)
      end
    end

    test "a locked command stops with exit 4 while another run holds the lock" do
      if System.find_executable("flock") do
        {:ok, release} = U.flock(Sys.path("/run/alnasl-system-update.lock"), :nb)
        out = quiet(fn -> assert U.main(["--check"]) == 4 end)
        assert out =~ "another run is busy"
        release.()
      end
    end

    test "blocking: waits for the holder" do
      if System.find_executable("flock") do
        path = Sys.path("/run/alnasl-system-update.status.lock")
        {:ok, release} = U.flock(path, :block)
        me = self()

        spawn_link(fn ->
          {:ok, r2} = U.flock(path, :block)
          send(me, :got)
          r2.()
        end)

        refute_receive :got, 300
        release.()
        assert_receive :got, 5000
      end
    end

    defp eventually(fun, n \\ 50) do
      cond do
        fun.() -> true
        n == 0 -> false
        true -> receive(after: (50 -> eventually(fun, n - 1)))
      end
    end
  end

  # ---- writing a slot (a fake zstd: cat; a regular file for the partition) ------------------------------
  describe "writing a slot" do
    @describetag :unix
    setup do
      Box.root!()
      seams!(root_part: fn -> {"mmcblk0", "mmcblk0p2", 2} end)
      Box.put("/sys/class/block/mmcblk0/mmcblk0p3/partition", "3\n")
      Box.put("/sys/class/block/mmcblk0/mmcblk0p3/size", "16\n")
      Box.put("/dev/mmcblk0p3", String.duplicate(<<0>>, 8192))
      Box.put("/proc/sys/vm/drop_caches", "")
      bin = Sys.path("/fakebin")
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "zstd"), "#!/bin/sh\n# -dc --no-progress FILE\nexec cat \"$3\"\n")
      File.chmod!(Path.join(bin, "zstd"), 0o755)
      path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> path)
      on_exit(fn -> System.put_env("PATH", path) end)

      # mkfifo really runs (the FIFO is the point); the card's commands are faked
      Box.runner!(fn
        ["mkfifo" | args] ->
          {out, rc} = System.cmd("mkfifo", args, stderr_to_stdout: true)
          {rc, out}

        _ ->
          nil
      end)

      :ok
    end

    test "a decompressor that fails is a failed unpack, never a hang" do
      File.write!(Sys.path("/fakebin/zstd"), "#!/bin/sh\necho broken >&2\nexit 3\n")
      dl = "/var/lib/alnasl-os-update/system/download/alnasl-system-v6.3.img.zst"
      Box.put(dl, "x")
      i = img("v6", "6.3", nil, raw_size: 10)

      assert {:refused, "the image did not unpack to what the index says (0 of 10 bytes)"} =
               U.attempt(fn -> quiet(fn -> U.write_slot(i, dl, "B", false) end) end)
    end

    test "unpacked, written, read back, labelled" do
      raw = :crypto.strong_rand_bytes(5000)
      Box.put("/var/lib/alnasl-os-update/system/download/alnasl-system-v6.3.img.zst", raw)
      i = img("v6", "6.3", nil, raw_size: 5000, raw_sha256: Base.encode16(:crypto.hash(:sha256, raw), case: :lower))
      dl = "/var/lib/alnasl-os-update/system/download/alnasl-system-v6.3.img.zst"
      quiet(fn -> assert U.write_slot(i, dl, "B", false) == "/dev/mmcblk0p3" end)
      assert binary_part(File.read!(Sys.path("/dev/mmcblk0p3")), 0, 5000) == raw
      assert byte_size(File.read!(Sys.path("/dev/mmcblk0p3"))) == 8192
      assert ["e2label", Sys.path("/dev/mmcblk0p3"), "ALNASL_B"] in Box.ran()
      assert File.read!(Sys.path("/proc/sys/vm/drop_caches")) == "1\n"
    end

    test "an image that unpacks to something else is refused" do
      raw = :crypto.strong_rand_bytes(5000)
      dl = "/var/lib/alnasl-os-update/system/download/alnasl-system-v6.3.img.zst"
      Box.put(dl, raw)
      i = img("v6", "6.3", nil, raw_size: 4000, raw_sha256: String.duplicate("0", 64))

      quiet(fn ->
        assert {:refused, "the image unpacks to more than the index says"} =
                 U.attempt(fn -> U.write_slot(i, dl, "B", false) end)
      end)

      i = img("v6", "6.3", nil, raw_size: 5000, raw_sha256: String.duplicate("0", 64))

      quiet(fn ->
        assert {:refused, "the image did not unpack to what the index says (5000 of 5000 bytes)"} =
                 U.attempt(fn -> U.write_slot(i, dl, "B", false) end)
      end)
    end

    test "an image larger than the slot is refused before anything is written" do
      dl = "/var/lib/alnasl-os-update/system/download/alnasl-system-v6.3.img.zst"
      Box.put(dl, "x")
      i = img("v6", "6.3", nil, raw_size: 9000)

      assert {:refused, "the image (0 MB) does not fit in slot B (0 MB)"} =
               U.attempt(fn -> U.write_slot(i, dl, "B", false) end)
    end
  end
end
