defmodule Mix.SCM.Git do
  @behavior Mix.SCM
  @moduledoc false

  def fetchable? do
    true
  end

  def format(opts) do
    opts[:git]
  end

  def format_lock(opts) do
    case opts[:lock] do
      { :git, _, lock_rev, lock_opts } ->
        lock = String.slice(lock_rev, 0, 7)
        case Enum.find_value [:branch, :ref, :tag], &List.keyfind(lock_opts, &1, 0) do
          { :ref, _ }  -> lock <> " (ref)"
          { key, val } -> lock <> " (#{key}: #{val})"
          nil          -> lock
        end
      _ ->
        nil
    end
  end

  def accepts_options(_app, opts) do
    cond do
      gh = opts[:github] ->
        opts |> Keyword.delete(:github) |> Keyword.put(:git, "git://github.com/#{gh}.git")
      opts[:git] ->
        opts
      true ->
        nil
    end
  end

  def checked_out?(opts) do
    File.dir?(Path.join(opts[:dest], ".git"))
  end

  def lock_status(opts) do
    case opts[:lock] do
      { :git, lock_repo, lock_rev, lock_opts } ->
        File.cd!(opts[:dest], fn ->
          rev_info = get_rev_info
          cond do
            lock_repo != opts[:git]          -> :outdated
            lock_opts != get_lock_opts(opts) -> :outdated
            lock_rev  != rev_info[:rev]      -> :mismatch
            lock_repo != rev_info[:origin]   -> :outdated
            true -> :ok
          end
        end)
      nil ->
        :mismatch
      _ ->
        :outdated
    end
  end

  def equal?(opts1, opts2) do
    get_lock(opts1, false) == get_lock(opts2, false)
  end

  def checkout(opts) do
    path     = opts[:dest]
    location = location(opts[:git])
    command  = %s(git clone --no-checkout --progress "#{location}" "#{path}")

    run_cmd_or_raise(command)
    File.cd! path, fn -> do_checkout(opts) end
  end

  def update(opts) do
    File.cd! opts[:dest], fn ->
      # Ensures origin is set the lock repo
      location = location(opts[:git])
      update_origin(location)

      command = "git fetch --force --progress"
      if opts[:tag] do
        command = command <> " --tags"
      end

      run_cmd_or_raise(command)
      do_checkout(opts)
    end
  end

  ## Helpers

  defp location("git://github.com/" <> rest) do
    if System.get_env("MIX_GIT_FORCE_HTTPS") == "1" do
      "https://github.com/" <> rest
    else
      "git://github.com/" <> rest
    end
  end

  defp location(other), do: other

  defp do_checkout(opts) do
    ref = get_lock_rev(opts[:lock]) || get_opts_rev(opts)
    run_cmd_or_raise "git checkout --quiet #{ref}"

    if opts[:submodules] do
      run_cmd_or_raise "git submodule update --init --recursive"
    end

    get_lock(opts, true)
  end

  defp get_lock(opts, fresh) do
    lock = if fresh do
             rev_info = get_rev_info
             rev_info[:rev]
           else
             get_lock_rev(opts[:lock])
           end
    { :git, opts[:git], lock, get_lock_opts(opts) }
  end

  defp get_lock_rev({ :git, _repo, lock, _opts }) when is_binary(lock), do: lock
  defp get_lock_rev(_), do: nil

  defp get_lock_opts(opts) do
    lock_opts = Enum.find_value [:branch, :ref, :tag], &List.keyfind(opts, &1, 0)
    lock_opts = List.wrap(lock_opts)
    if opts[:submodules] do
      lock_opts ++ [submodules: true]
    else
      lock_opts
    end
  end

  defp get_opts_rev(opts) do
    if branch = opts[:branch] do
      "origin/#{branch}"
    else
      opts[:ref] || opts[:tag] || "origin/master"
    end
  end

  defp get_rev_info do
    destructure [origin, rev],
      System.cmd('git config remote.origin.url && git rev-parse --verify --quiet HEAD')
      |> iolist_to_binary
      |> String.split("\n", trim: true)
    [ origin: origin, rev: rev ]
  end

  defp update_origin(location) do
    System.cmd('git config remote.origin.url #{location}')
  end

  defp run_cmd_or_raise(command) do
    if Mix.shell.cmd(command) != 0 do
      raise Mix.Error, message: "Command `#{command}` failed"
    end
    true
  end
end
