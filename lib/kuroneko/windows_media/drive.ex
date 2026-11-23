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
  alias Kuroneko.WindowsMedia.WIM

  @sector 512
  @start 1024 * 1024
  @fat32_max 4 * 1024 * 1024 * 1024 - 1
  @part_bytes 3800 * 1024 * 1024
  @cluster 32 * 1024
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
             {:ok, entries} <- entries(iso_dir),
             plan = plan(iso_dir, entries),
             size = drive_size(plan),
             :ok <- room(size, Keyword.get(opts, :free)),
             :ok <- disk(image, size),
             :ok <- format(image, size - @start, Keyword.get(opts, :label)) do
          fill(image, plan, progress)
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

  @doc false
  # Every directory and file of a tree, relative, parents first, with the
  # files' sizes.
  @spec entries(Path.t()) :: {:ok, [{Path.t(), :dir | non_neg_integer()}]} | {:error, term()}
  def entries(root) do
    with {:ok, acc} <- walk(root, "", []), do: {:ok, Enum.reverse(acc)}
  end

  defp walk(root, relative, acc) do
    with {:ok, names} <- File.ls(Path.join(root, relative)) do
      names
      |> Enum.sort()
      |> Enum.map(&if(relative == "", do: &1, else: Path.join(relative, &1)))
      |> Enum.reduce_while({:ok, acc}, &entry_or_halt(root, &1, &2))
    end
  end

  defp entry_or_halt(root, path, {:ok, acc}) do
    case entry(root, path, acc) do
      {:ok, acc} -> {:cont, {:ok, acc}}
      error -> {:halt, error}
    end
  end

  # A directory with what it holds, a file with its size; nothing else.
  defp entry(root, path, acc) do
    case File.lstat(Path.join(root, path)) do
      {:ok, %{type: :directory}} -> walk(root, path, [{path, :dir} | acc])
      {:ok, %{type: :regular, size: size}} -> {:ok, [{path, size} | acc]}
      {:ok, _other} -> {:ok, acc}
      error -> error
    end
  end

  @doc false
  # What goes on the drive: the files as they are, but for a WIM too large
  # for FAT32, split; and what cannot go at all.
  @spec plan(Path.t(), [{Path.t(), :dir | non_neg_integer()}]) :: map()
  def plan(root, entries) do
    {split, copy} =
      Enum.split_with(entries, fn {path, size} ->
        is_integer(size) and size > @fat32_max and String.downcase(Path.extname(path)) == ".wim"
      end)

    %{root: root, copy: copy, split: Enum.map(split, &elem(&1, 0))}
  end

  @doc false
  # The bytes the drive takes: each file and directory in clusters, room
  # for the FATs and the split parts' headers, and some to spare.
  @spec drive_size(map()) :: pos_integer()
  def drive_size(%{copy: copy, split: split, root: root}) do
    files =
      Enum.reduce(copy, 0, fn
        {_path, :dir}, acc -> acc + @cluster
        {_path, size}, acc -> acc + div(size + @cluster - 1, @cluster) * @cluster
      end)

    split_bytes =
      Enum.reduce(split, 0, &(&2 + File.stat!(Path.join(root, &1)).size + 64 * 1024 * 1024))

    data = files + split_bytes
    # Two FATs of 4 bytes a 4 KiB cluster at most, and 128 MiB to spare.
    round_up(@start + data + div(data, 512) + 128 * 1024 * 1024, @start)
  end

  defp round_up(n, unit), do: div(n + unit - 1, unit) * unit

  defp room(_size, nil), do: :ok
  defp room(size, free) when size <= free, do: :ok
  defp room(size, free), do: {:error, {:no_room, size, free}}

  # A sparse file of the drive's size with its MBR.
  defp disk(image, size) do
    with {:ok, file} <- File.open(image, [:write, :binary, :raw]) do
      try do
        with :ok <- :file.pwrite(file, 0, mbr(div(size, @sector))),
             {:ok, _at} <- :file.position(file, size),
             do: :file.truncate(file)
      after
        File.close(file)
      end
    end
  end

  @doc false
  # The MBR: a FAT32 (LBA) partition from sector 2048 to the end, active.
  # Its code asks the BIOS for the next boot device (INT 18h).
  @spec mbr(pos_integer()) :: binary()
  def mbr(sectors) do
    first = div(@start, @sector)

    entry =
      <<0x80, 0xFE, 0xFF, 0xFF, 0x0C, 0xFE, 0xFF, 0xFF, first::little-32,
        sectors - first::little-32>>

    <<0xCD, 0x18, 0::size(438 * 8), :crypto.strong_rand_bytes(4)::binary, 0::16, entry::binary,
      0::size(48 * 8), 0x55, 0xAA>>
  end

  # Kuroneko's FAT32, in the partition: there when this runs in Kuroneko.
  @compile {:no_warn_undefined, FAT}
  @dialyzer {:nowarn_function, format: 3}
  defp format(image, size, label),
    do: FAT.format(image, size, label: label || "WINDOWS", offset: @start)

  defp fill(image, plan, progress) do
    drive_dir = image <> ".fat"

    with :ok <- File.mkdir_p(drive_dir),
         {:ok, loop} <- attach(image),
         :ok <- mount_drive(loop, drive_dir) do
      try do
        total = total_bytes(plan)

        with {:ok, done} <- copy(plan, drive_dir, {0, total, progress}) do
          split(plan, drive_dir, {done, total, progress})
        end
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
  defp attach(image) do
    with {:ok, free} <- output("losetup", ["-f"]),
         loop = String.trim(free),
         :ok <- run("losetup", ["-o", Integer.to_string(@start), loop, image]),
         do: {:ok, loop}
  end

  defp total_bytes(%{copy: copy, split: split, root: root}) do
    copied =
      Enum.reduce(copy, 0, fn {_path, size}, acc ->
        if is_integer(size), do: acc + size, else: acc
      end)

    copied + Enum.reduce(split, 0, &(&2 + File.stat!(Path.join(root, &1)).size))
  end

  defp copy(%{copy: copy, root: root}, to, progress) do
    Enum.reduce_while(copy, {:ok, progress}, fn
      {path, :dir}, {:ok, progress} ->
        case File.mkdir_p(Path.join(to, path)) do
          :ok -> {:cont, {:ok, progress}}
          error -> {:halt, error}
        end

      {path, _size}, {:ok, progress} ->
        case copy_file(Path.join(root, path), Path.join(to, path), progress) do
          {:ok, progress} -> {:cont, {:ok, progress}}
          error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, {done, _total, _report}} -> {:ok, done}
      error -> error
    end
  end

  defp copy_file(from, to, progress) do
    with {:ok, input} <- File.open(from, [:read, :binary, :raw]) do
      try do
        with {:ok, output} <- File.open(to, [:write, :binary, :raw]) do
          try do
            stream(input, output, progress)
          after
            File.close(output)
          end
        end
      after
        File.close(input)
      end
    end
  end

  defp stream(input, output, {done, total, report} = progress) do
    case :file.read(input, @chunk) do
      {:ok, data} ->
        with :ok <- IO.binwrite(output, data) do
          done = done + byte_size(data)
          report.(done, total)
          stream(input, output, {done, total, report})
        end

      :eof ->
        {:ok, progress}

      error ->
        error
    end
  end

  defp split(%{split: split, root: root}, to, {done, total, report}) do
    Enum.reduce_while(split, {:ok, done}, fn path, {:ok, done} ->
      case split_wim(
             Path.join(root, path),
             Path.join(to, Path.dirname(path)),
             {done, total, report}
           ) do
        {:ok, size} -> {:cont, {:ok, done + size}}
        {:error, reason} -> {:halt, {:error, {:split, path, reason}}}
      end
    end)
    |> case do
      {:ok, _done} -> :ok
      error -> error
    end
  end

  # A WIM as install.swm, install2.swm, ...: Windows Setup's names for it.
  defp split_wim(wim, dir, {done, total, report}) do
    name = Path.rootname(Path.basename(wim))
    progress = fn n, _wim_total -> report.(done + n, total) end

    with {:ok, _parts} <- WIM.split(wim, dir, name, @part_bytes, progress),
         do: {:ok, File.stat!(wim).size}
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
