defmodule DartSass do
  @moduledoc """
  DartSass is an installer and runner for [Dart Sass](https://sass-lang.com/dart-sass).

  ## Profiles

  You can define multiple configuration profiles. By default, there is a
  profile called `:default` where you can configure its `args`,
  current working directory and environment variables:

      config :dart_sass,
        version: "1.61.0",
        default: [
          args: ~w(css/app.scss ../priv/static/assets/app.css),
          cd: Path.expand("../assets", __DIR__)
        ]

  For multiple CSS outputs separate source and destination with a colon:

      [
        "css/app.scss:../priv/static/assets/app.css",
        "css/admin.scss:../priv/static/assets/admin.css",
      ]

  ## DartSass configuration

  There are two global configurations for the `dart_sass` application:

    * `:version` - the expected `sass` version.

    * `:path` - the path to the `sass` executable. By default
      it is automatically downloaded and placed inside the `_build` directory
      of your current app. Note that if your system architecture requires a
      separate Dart VM executable to run, then `:path` should be defined as a
      list of absolute paths.

  Overriding the `:path` is not recommended, as we will automatically
  download and manage `sass` for you. But in case you can't download
  it (for example, the GitHub releases are behind a proxy), you may want to
  set the `:path` to a configurable system location.

  For instance, you can install `sass` globally with `npm`:

      $ npm install -g sass

  Then the executable will be at:

      $ ls "$NPM_ROOT/sass/sass.js"

  Where `$NPM_ROOT` is the result of `npm root -g`.

  Once you find the location of the executable, you can store it in a
  `$MIX_SASS_PATH` environment variable, which you can then read in
  your configuration file:

      config :dart_sass, path: System.get_env("MIX_SASS_PATH")

  Note that overriding `:path` disables version checking.
  """

  use Application
  require Logger

  @doc false
  def start(_, _) do
    unless Application.get_env(:dart_sass, :path) do
      unless Application.get_env(:dart_sass, :version) do
        Logger.warn("""
        dart_sass version is not configured. Please set it in your config files:

            config :dart_sass, :version, "#{latest_version()}"
        """)
      end

      configured_version = configured_version()

      case bin_version() do
        {:ok, ^configured_version} ->
          :ok

        {:ok, version} ->
          Logger.warn("""
          Outdated dart-sass version. Expected #{configured_version}, got #{version}. \
          Please run `mix sass.install` or update the version in your config files.\
          """)

        :error ->
          :ok
      end
    end

    Supervisor.start_link([], strategy: :one_for_one)
  end

  @doc false
  # Latest known version at the time of publishing.
  def latest_version, do: "1.61.0"

  @doc """
  Returns the configured `sass` version.
  """
  def configured_version do
    Application.get_env(:dart_sass, :version, latest_version())
  end

  @doc """
  Returns the configuration for the given profile.

  Returns nil if the profile does not exist.
  """
  def config_for!(profile) when is_atom(profile) do
    Application.get_env(:dart_sass, profile) ||
      raise ArgumentError, """
      unknown dart_sass profile. Make sure the profile named #{inspect(profile)} is defined in your config files, such as:

          config :dart_sass,
            #{profile}: [
              args: ["css/app.scss:../priv/static/assets/app.css"],
              cd: Path.expand("../assets", __DIR__)
            ]
      """
  end

  defp dest_bin_paths(platform, base_path) do
    target = target(platform)
    ["dart", "sass.snapshot"] |> Enum.map(&Path.join(base_path, "#{&1}-#{target}"))
  end

  @doc """
  Returns the path to the `dart` VM executable and to the `sass` executable.
  """
  def bin_paths do
    cond do
      env_path = Application.get_env(:dart_sass, :path) ->
        List.wrap(env_path)

      Code.ensure_loaded?(Mix.Project) ->
        dest_bin_paths(platform(), Path.dirname(Mix.Project.build_path()))

      true ->
        dest_bin_paths(platform(), "_build")
    end
  end

  # TODO: Remove when dart-sass will exit when stdin is closed.
  @doc false
  def script_path() do
    Path.join(:code.priv_dir(:dart_sass), "dart_sass.bash")
  end

  @doc """
  Returns the version of the `sass` executable (or snapshot).

  Returns `{:ok, version_string}` on success or `:error` when the executable
  is not available.
  """
  def bin_version do
    with paths = bin_paths(),
         true <- paths_exist?(paths),
         {result, 0} <- run_cmd(paths, ["--version"]) do
      {:ok, String.trim(result)}
    else
      _ -> :error
    end
  end

  defp run_cmd([command_path | bin_paths], extra_args, opts \\ []),
    do: System.cmd(command_path, bin_paths ++ extra_args, opts)

  @doc """
  Runs the given command with `args`.

  The given args will be appended to the configured args.
  The task output will be streamed directly to stdio. It
  returns the status of the underlying call.
  """
  def run(profile, extra_args) when is_atom(profile) and is_list(extra_args) do
    config = config_for!(profile)
    config_args = config[:args] || []

    opts = [
      cd: config[:cd] || File.cwd!(),
      env: config[:env] || %{},
      into: IO.stream(:stdio, :line),
      stderr_to_stdout: true
    ]

    args = config_args ++ extra_args

    # TODO: Remove when dart-sass will exit when stdin is closed.
    # Link: https://github.com/sass/dart-sass/pull/1411
    paths =
      if "--watch" in args and platform() != :windows,
        do: [script_path() | bin_paths()],
        else: bin_paths()

    run_cmd(paths, args, opts) |> elem(1)
  end

  @doc """
  Installs, if not available, and then runs `sass`.

  Returns the same as `run/2`.
  """
  def install_and_run(profile, args) do
    paths_exist?(bin_paths()) || install()
    run(profile, args)
  end

  @doc """
  Installs `dart-sass` with `configured_version/0`.
  """
  def install do
    version = configured_version()
    tmp_opts = if System.get_env("MIX_XDG"), do: %{os: :linux}, else: %{}

    tmp_dir =
      fresh_mkdir_p(:filename.basedir(:user_cache, "cs-sass", tmp_opts)) ||
        fresh_mkdir_p(Path.join(System.tmp_dir!(), "cs-sass")) ||
        raise "could not install sass. Set MIX_XDG=1 and then set XDG_CACHE_HOME to the path you want to use as cache"

    platform = platform()

    (platform == :linux and Version.match?(version, "> 1.57.1")) or
      raise "versions 1.57.1 and lower are not supported anymore on Linux " <>
              "due to changes to the package structure"

    name = "dart-sass-#{version}-#{target_extname(platform)}"
    url = "https://github.com/sass/dart-sass/releases/download/#{version}/#{name}"
    archive = fetch_body!(url)

    case unpack_archive(Path.extname(name), archive, tmp_dir) do
      :ok -> :ok
      other -> raise "couldn't unpack archive: #{inspect(other)}"
    end

    [dart, snapshot] = bin_paths()

    bin_suffix = if platform == :windows, do: ".exe", else: ""

    [{"dart#{bin_suffix}", dart}, {"sass.snapshot", snapshot}]
    |> Enum.each(fn {src_name, dest_path} ->
      File.rm(dest_path)
      File.cp!(Path.join([tmp_dir, "dart-sass", "src", src_name]), dest_path)
    end)
  end

  defp platform do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, :linux} -> :linux
      {:unix, osname} -> raise "dart_sass is not available for osname: #{inspect(osname)}"
      {:win32, _} -> :windows
    end
  end

  defp paths_exist?(paths) do
    paths |> Enum.all?(&File.exists?/1)
  end

  defp fresh_mkdir_p(path) do
    with {:ok, _} <- File.rm_rf(path),
         :ok <- File.mkdir_p(path) do
      path
    else
      _ -> nil
    end
  end

  defp unpack_archive(".zip", zip, cwd) do
    with {:ok, _} <- :zip.unzip(zip, cwd: to_charlist(cwd)), do: :ok
  end

  defp unpack_archive(_, tar, cwd) do
    :erl_tar.extract({:binary, tar}, [:compressed, cwd: to_charlist(cwd)])
  end

  defp target_extname(platform) do
    target = target(platform)

    case platform do
      :windows -> "#{target}.zip"
      _ -> "#{target}.tar.gz"
    end
  end

  # Available targets: https://github.com/sass/dart-sass/releases
  defp target(:windows) do
    case :erlang.system_info(:wordsize) * 8 do
      32 -> "windows-ia32"
      64 -> "windows-x64"
    end
  end

  defp target(platform) do
    arch_str = :erlang.system_info(:system_architecture)

    # TODO: remove "arm" when we require OTP 24
    case arch_str |> List.to_string() |> String.split("-") |> hd() do
      a when a in ~w[amd64 x86_64] -> "#{platform}-x64"
      a when a in ~w[i386 i686] -> "#{platform}-ia32"
      a when a in ~w[arm aarch64] -> "#{platform}-arm64"
      _ -> raise "dart_sass not available for architecture: #{arch_str}"
    end
  end

  defp fetch_body!(url) do
    url = String.to_charlist(url)
    Logger.debug("Downloading dart-sass from #{url}")

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    http_proxy = System.get_env("HTTP_PROXY") || System.get_env("http_proxy")
    https_proxy = System.get_env("HTTPS_PROXY") || System.get_env("https_proxy")

    if proxy = https_proxy || http_proxy do
      Logger.debug("Using HTTP#{https_proxy && "S"}_PROXY: #{proxy}")
      %{host: host, port: port} = URI.parse(proxy)
      option_name = :"#{https_proxy && :https_}proxy"
      :httpc.set_options([{option_name, {{String.to_charlist(host), port}, []}}])
    end

    http_options = [
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        # https://erlef.github.io/security-wg/secure_coding_and_deployment_hardening/inets
        cacertfile: cacertfile() |> String.to_charlist(),
        depth: 2,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ],
        versions: protocol_versions()
      ]
    ]

    with {_, {:ok, {{_, 302, _}, headers, _}}} <-
           {:redir, :httpc.request(:get, {url, []}, http_options, [])},
         {_, {'location', dl_url}, _} <-
           {:loctn, List.keyfind(headers, 'location', 0), headers},
         {_, {:ok, {{_, 200, _}, _, body}}, _} <-
           {:dload, :httpc.request(:get, {dl_url, []}, http_options, body_format: :binary),
            dl_url} do
      {:body, body}
    end
    |> case do
      {:redir, error} -> raise "couldn't fetch #{url}: #{inspect(error)}"
      {:loctn, _, headers} -> raise "couldn't find 'location' header in: #{inspect(headers)}"
      {:dload, error, dl_url} -> raise "couldn't fetch #{dl_url}: #{inspect(error)}"
      {:body, body} -> body
    end
  end

  defp protocol_versions do
    [:"tlsv1.2"] ++ if(otp_version() >= 25, do: [:"tlsv1.3"], else: [])
  end

  defp otp_version do
    :erlang.system_info(:otp_release) |> List.to_integer()
  end

  defp cacertfile() do
    Application.get_env(:dart_sass, :cacerts_path) || CAStore.file_path()
  end
end
