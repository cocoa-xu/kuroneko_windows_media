defmodule Kuroneko.WindowsMedia.Layout do
  @moduledoc false

  @sector 512
  @start 1024 * 1024
  @cluster 32 * 1024
  @fat32_max 4 * 1024 * 1024 * 1024 - 1
  @split_overhead 64 * 1024 * 1024
  @spare 128 * 1024 * 1024

  @enforce_keys [:entries, :size, :bytes]
  defstruct [:entries, :size, :bytes, start: @start]

  @type entry() :: {:dir, Path.t()} | {:file | :split, Path.t(), non_neg_integer()}

  @type t() :: %__MODULE__{
          entries: [entry()],
          start: pos_integer(),
          size: pos_integer(),
          bytes: non_neg_integer()
        }

  @spec entries(Path.t()) :: {:ok, [entry()]} | {:error, File.posix()}
  def entries(root) do
    with {:ok, children} <- children(root, ""), do: walk(root, children, [])
  end

  defp walk(_root, [], acc), do: {:ok, Enum.reverse(acc)}

  defp walk(root, [path | paths], acc) do
    case File.lstat(Path.join(root, path)) do
      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, children} <- children(root, path),
             do: walk(root, children ++ paths, [{:dir, path} | acc])

      {:ok, %File.Stat{type: :regular, size: size}} ->
        walk(root, paths, [{:file, path, size} | acc])

      {:ok, %File.Stat{}} ->
        walk(root, paths, acc)

      {:error, _reason} = error ->
        error
    end
  end

  defp children(root, dir) do
    with {:ok, names} <- File.ls(Path.join(root, dir)),
         do: {:ok, for(name <- Enum.sort(names), do: Path.join(dir, name))}
  end

  @spec new([entry()]) :: t()
  def new(entries) do
    entries = Enum.map(entries, &split_large_wim/1)
    data = entries |> Enum.map(&footprint/1) |> Enum.sum()
    # Two FATs of 4 bytes a cluster, of 4 KiB at least: 1/512 of the data.
    size = round_up(@start + data + div(data, 512) + @spare, @start)

    %__MODULE__{entries: entries, size: size, bytes: entries |> Enum.map(&bytes/1) |> Enum.sum()}
  end

  defp split_large_wim({:file, path, size} = entry) do
    if size > @fat32_max and String.downcase(Path.extname(path)) == ".wim",
      do: {:split, path, size},
      else: entry
  end

  defp split_large_wim({:dir, _path} = entry), do: entry

  defp footprint({:dir, _path}), do: @cluster
  defp footprint({:file, _path, size}), do: round_up(size, @cluster)
  defp footprint({:split, _path, size}), do: size + @split_overhead

  defp bytes({:dir, _path}), do: 0
  defp bytes({_file_or_split, _path, size}), do: size

  defp round_up(n, unit), do: div(n + unit - 1, unit) * unit

  # A FAT32 (LBA) partition from the layout's start to the end, active. The
  # code asks the BIOS for the next boot device (INT 18h).
  @spec mbr(t()) :: <<_::4096>>
  def mbr(%__MODULE__{start: start, size: size}) do
    first = div(start, @sector)

    entry =
      <<0x80, 0xFE, 0xFF, 0xFF, 0x0C, 0xFE, 0xFF, 0xFF, first::little-32,
        div(size, @sector) - first::little-32>>

    <<0xCD, 0x18, 0::size(438)-unit(8), :crypto.strong_rand_bytes(4)::binary, 0::16,
      entry::binary, 0::size(48)-unit(8), 0x55, 0xAA>>
  end
end
