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
  Makes `image` from the ISO at `iso`, telling `progress` the bytes done
  and their total. `free` is the room it may take.
  """
  @spec make(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def make(iso, image, opts) do
    progress = Keyword.get(opts, :progress, fn _done, _total -> :ok end)
    iso_dir = image <> ".iso"

    with :ok <- File.mkdir_p(iso_dir),
         :ok <- run("mount", ["-t", "udf", "-o", "loop,ro", iso, iso_dir]) do
      try do
        with :ok <- windows_installer(iso_dir),
             {:ok, entries} <- Layout.entries(iso_dir),
             layout = Layout.new(entries),
             :ok <- room(layout.size, Keyword.get(opts, :free)),
             :ok <- disk(image, layout),
             :ok <- format(image, layout, Keyword.get(opts, :label)) do
          fill(image, iso_dir, layout, progress)
        end
      after
        _ = run("umount", [iso_dir])
        File.rmdir(iso_dir)
      end
    end
  end

  # What Windows Setup needs, and UEFI to start it.
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

  defp room(_size, nil), do: :ok
  defp room(size, free) when size <= free, do: :ok
  defp room(size, free), do: {:error, {:no_room, size, free}}

  defp disk(image, layout) do
    with {:ok, file} <- File.open(image, [:write, :binary, :raw]) do
      try do
        with :ok <- :file.pwrite(file, 0, Layout.mbr(layout)),
             {:ok, _at} <- :file.position(file, layout.size),
             do: :file.truncate(file)
      after
        File.close(file)
      end
    end
  end

  # Kuroneko's FAT32, in the partition: there when this runs in Kuroneko.
  @compile {:no_warn_undefined, FAT}
  @dialyzer {:nowarn_function, format: 3}
  defp format(image, layout, label),
    do:
      FAT.format(image, layout.size - layout.start,
        label: label || "WINDOWS",
        offset: layout.start
      )

  defp fill(image, root, layout, progress) do
    drive_dir = image <> ".fat"

    with :ok <- File.mkdir_p(drive_dir),
         {:ok, loop} <- attach(image, layout.start),
         :ok <- mount_drive(loop, drive_dir) do
      try do
        write(layout.entries, root, drive_dir, 0, &progress.(&1, layout.bytes))
      after
        _ = run("umount", [drive_dir])
        _ = run("losetup", ["-d", loop])
        _ = File.rmdir(drive_dir)
      end
    else
      error ->
        _ = File.rmdir(drive_dir)
        error
    end
  end

  defp mount_drive(loop, dir) do
    case run("mount", ["-t", "vfat", "-o", "utf8,shortname=mixed", loop, dir]) do
      :ok ->
        :ok

      error ->
        _ = run("losetup", ["-d", loop])
        error
    end
  end

  # A loop device on the partition.
  defp attach(image, offset) do
    with {:ok, free} <- output("losetup", ["-f"]),
         loop = String.trim(free),
         :ok <- run("losetup", ["-o", Integer.to_string(offset), loop, image]),
         do: {:ok, loop}
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
    with {:ok, input} <- File.open(from, [:read, :binary, :raw]) do
      try do
        with {:ok, output} <- File.open(to, [:write, :binary, :raw]) do
          try do
            stream(input, output, done, report)
          after
            File.close(output)
          end
        end
      after
        File.close(input)
      end
    end
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

  defp run(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {command, String.trim(output)}}
    end
  rescue
    error in ErlangError -> {:error, {command, error.original}}
  end

  defp output(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, {command, String.trim(output)}}
    end
  rescue
    error in ErlangError -> {:error, {command, error.original}}
  end
end
