defmodule Kuroneko.WindowsMedia.Drive do
  @moduledoc """
  A USB drive image from a Windows installer's ISO, as UEFI starts it: an
  MBR and one FAT32 partition from 1 MiB on, holding the ISO's files. An
  `install.wim` larger than a FAT32 file can be goes in as `install.swm`
  parts (`Kuroneko.WindowsMedia.WIM`), which Windows Setup installs from.

  The drive starts with UEFI, Secure Boot on or off, from the ISO's own
  `\\efi\\boot\\bootx64.efi`, signed by Microsoft. A BIOS skips it: its MBR
  only asks for the next boot device. The ISO's optical drive is the way
  for a BIOS.

  Making it mounts the ISO (UDF) and the partition (vfat) through loop
  devices: Linux, as root, with `losetup`, as Kuroneko's Nerves system has.
  """

  alias Kuroneko.VirtualDisk.FAT
  alias Kuroneko.WindowsMedia.{Layout, WIM}

  @part_bytes 3800 * 1024 * 1024
  @chunk 1_048_576

  @doc """
  Makes `image` a USB drive with the files of the Windows installer's ISO
  at `iso`.

  Options:

    * `:label` - the drive's name, `"WINDOWS"` when `nil` or not given
    * `:free` - the bytes the drive may take, `:infinity` by default; a
      larger drive gives `{:error, {:no_room, size, free}}`
    * `:progress` - a `t:Kuroneko.WindowsMedia.progress/0`, told the bytes
      of the ISO's files written and their total

  An ISO without Windows Setup and its UEFI boot loader gives
  `{:error, :not_a_windows_installer}`.
  """
  @spec make(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def make(iso, image, opts) do
    opts =
      Keyword.validate!(opts, label: nil, free: :infinity, progress: fn _done, _total -> :ok end)

    with_mount(iso, image <> ".iso", ["-t", "udf", "-o", "loop,ro"], fn root ->
      with :ok <- windows_installer(root),
           {:ok, entries} <- Layout.entries(root),
           layout = Layout.new(entries),
           :ok <- room(layout.size, opts[:free]),
           :ok <- disk(image, layout),
           :ok <- format(image, layout, opts[:label] || "WINDOWS") do
        fill(image, root, layout, opts[:progress])
      end
    end)
  end

  defp windows_installer(dir) do
    install =
      Enum.any?(
        ["install.wim", "install.esd", "install.swm"],
        &File.regular?(Path.join([dir, "sources", &1]))
      )

    if install and File.regular?(Path.join([dir, "sources", "boot.wim"])) and
         File.regular?(Path.join([dir, "efi", "boot", "bootx64.efi"])),
       do: :ok,
       else: {:error, :not_a_windows_installer}
  end

  defp room(_size, :infinity), do: :ok
  defp room(size, free) when is_integer(free) and size <= free, do: :ok
  defp room(size, free) when is_integer(free), do: {:error, {:no_room, size, free}}

  defp disk(image, layout) do
    with_file(image, [:write, :binary, :raw], fn file ->
      with :ok <- :file.pwrite(file, 0, Layout.mbr(layout)),
           {:ok, _position} <- :file.position(file, layout.size),
           do: :file.truncate(file)
    end)
  end

  # Kuroneko's FAT32, in the partition: there when this runs in Kuroneko.
  @compile {:no_warn_undefined, FAT}
  @dialyzer {:nowarn_function, format: 3}
  defp format(image, layout, label),
    do: FAT.format(image, layout.size - layout.start, label: label, offset: layout.start)

  defp fill(image, root, layout, progress) do
    with_loop(image, layout.start, fn loop ->
      with_mount(loop, image <> ".fat", ["-t", "vfat", "-o", "utf8,shortname=mixed"], fn drive ->
        write(layout.entries, root, drive, 0, &progress.(&1, layout.bytes))
      end)
    end)
  end

  defp write([], _from, _to, _done, _report), do: :ok

  defp write([{:dir, path} | entries], from, to, done, report) do
    with :ok <- File.mkdir_p(Path.join(to, path)), do: write(entries, from, to, done, report)
  end

  defp write([{:file, path, size} | entries], from, to, done, report) do
    with :ok <- copy_file(Path.join(from, path), Path.join(to, path), done, report),
         do: write(entries, from, to, done + size, report)
  end

  defp write([{:split, path, size} | entries], from, to, done, report) do
    opts = [max_bytes: @part_bytes, progress: fn n, _total -> report.(done + n) end]

    case WIM.split(Path.join(from, path), Path.join(to, Path.dirname(path)), opts) do
      {:ok, _parts} -> write(entries, from, to, done + size, report)
      {:error, reason} -> {:error, {:split, path, reason}}
    end
  end

  defp copy_file(from, to, done, report) do
    with_file(from, [:read, :binary, :raw], fn input ->
      with_file(to, [:write, :binary, :raw], &stream(input, &1, done, report))
    end)
  end

  defp stream(input, output, done, report) do
    case :file.read(input, @chunk) do
      {:ok, data} ->
        with :ok <- IO.binwrite(output, data) do
          done = done + byte_size(data)
          report.(done)
          stream(input, output, done, report)
        end

      :eof ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp with_mount(device, dir, options, fun) do
    with :ok <- File.mkdir_p(dir) do
      try do
        with {:ok, _output} <- cmd("mount", options ++ [device, dir]) do
          try do
            fun.(dir)
          after
            cmd("umount", [dir])
          end
        end
      after
        File.rmdir(dir)
      end
    end
  end

  defp with_loop(image, offset, fun) do
    with {:ok, free} <- cmd("losetup", ["-f"]),
         loop = String.trim(free),
         {:ok, _output} <- cmd("losetup", ["-o", Integer.to_string(offset), loop, image]) do
      try do
        fun.(loop)
      after
        cmd("losetup", ["-d", loop])
      end
    end
  end

  defp with_file(path, modes, fun) do
    with {:ok, result} <- File.open(path, modes, fun), do: result
  end

  defp cmd(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, {command, String.trim(output)}}
    end
  rescue
    error in ErlangError -> {:error, {command, error.original}}
  end
end
