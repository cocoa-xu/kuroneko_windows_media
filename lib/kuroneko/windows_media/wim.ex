defmodule Kuroneko.WindowsMedia.WIM do
  @moduledoc """
  Splits a Windows image (WIM) file into parts no larger than a size, as
  `Dism /Split-Image` does, so that a WIM larger than FAT32's 4 GiB files
  fits on a FAT32 drive: `install.swm`, `install2.swm` and so on, which
  Windows Setup installs from.

  The resources are copied as they are, compressed: each part has the
  original's header with its part number, the resources it holds and a
  lookup table of them, and the XML data. The first part holds the images'
  metadata. Solid WIMs, whose resources hold several files together (most
  ESD files), are not split.
  """

  import Bitwise

  @header_size 208
  @entry_size 50
  @chunk 1_048_576

  @flag_spanned 0x8
  @resource_metadata 0x2
  @resource_solid 0x10

  @typedoc "A resource of the WIM, as its lookup table has it."
  @type entry() :: %{
          size: non_neg_integer(),
          flags: byte(),
          offset: non_neg_integer(),
          original: non_neg_integer(),
          part: non_neg_integer(),
          refs: non_neg_integer(),
          hash: binary()
        }

  @doc """
  Splits `source` into parts in `dir` named after `name` (`"install"` gives
  `install.swm`, `install2.swm`, ...), none larger than `max_bytes`.
  `progress` hears the bytes of resources copied and their total. Gives the
  parts' paths.
  """
  @spec split(Path.t(), Path.t(), String.t(), pos_integer(), (non_neg_integer(),
                                                              non_neg_integer() ->
                                                                any())) ::
          {:ok, [Path.t()]} | {:error, term()}
  def split(source, dir, name, max_bytes, progress \\ fn _done, _total -> :ok end) do
    with {:ok, file} <- File.open(source, [:read, :binary, :raw]) do
      try do
        with {:ok, header} <- read_header(file),
             :ok <- if(header.parts == 1, do: :ok, else: {:error, :already_split}),
             {:ok, entries} <- read_table(file, header.table),
             {:ok, xml} <- pread(file, header.xml.offset, header.xml.size),
             :ok <-
               if(Enum.any?(entries, &((&1.flags &&& @resource_solid) != 0)),
                 do: {:error, :solid},
                 else: :ok
               ),
             {:ok, parts} <- assign(entries, max_bytes - overhead(entries, xml)) do
          total = entries |> Enum.map(& &1.size) |> Enum.sum()
          write_parts(file, header, xml, parts, dir, name, {0, total, progress})
        end
      after
        File.close(file)
      end
    end
  end

  # The header, the lookup table and the XML data a part holds besides its
  # resources, at most: the XML may grow by a few digits.
  defp overhead(entries, xml),
    do: @header_size + length(entries) * @entry_size + byte_size(xml) + 64

  @doc false
  @spec read_header(:file.io_device()) :: {:ok, map()} | {:error, term()}
  def read_header(file) do
    case pread(file, 0, @header_size) do
      {:ok,
       <<"MSWIM", 0, 0, 0, @header_size::little-32, version::little-32, flags::little-32,
         chunk::little-32, guid::binary-size(16), part::little-16, parts::little-16,
         images::little-32, table::binary-size(24), xml::binary-size(24), boot::binary-size(24),
         boot_index::little-32, integrity::binary-size(24), _unused::binary-size(60)>>} ->
        header = %{
          version: version,
          flags: flags,
          chunk: chunk,
          guid: guid,
          part: part,
          parts: parts,
          images: images,
          table: reshdr(table),
          xml: reshdr(xml),
          boot: reshdr(boot),
          boot_index: boot_index,
          integrity: reshdr(integrity)
        }

        {:ok, header}

      {:ok, _other} ->
        {:error, :not_a_wim}

      error ->
        error
    end
  end

  defp reshdr(<<size::little-56, flags, offset::little-64, original::little-64>>),
    do: %{size: size, flags: flags, offset: offset, original: original}

  defp reshdr_binary(%{size: size, flags: flags, offset: offset, original: original}),
    do: <<size::little-56, flags, offset::little-64, original::little-64>>

  @empty_reshdr %{size: 0, flags: 0, offset: 0, original: 0}

  defp read_table(file, %{offset: offset, size: size}) do
    with {:ok, table} <- pread(file, offset, size) do
      entries =
        for <<resource::binary-size(24), part::little-16, refs::little-32,
              hash::binary-size(20) <- table>> do
          resource |> reshdr() |> Map.merge(%{part: part, refs: refs, hash: hash})
        end

      {:ok, entries}
    end
  end

  @doc false
  # The parts' resources: the metadata first, in the order of the images,
  # then the others as the file has them, a part filled before the next.
  @spec assign([entry()], integer()) :: {:ok, [[entry()]]} | {:error, term()}
  def assign(entries, room) do
    {metadata, others} = Enum.split_with(entries, &((&1.flags &&& @resource_metadata) != 0))
    ordered = metadata ++ Enum.sort_by(others, & &1.offset)

    cond do
      room <= 0 ->
        {:error, :part_too_small}

      big = Enum.find(ordered, &(&1.size > room)) ->
        {:error, {:resource_too_large, big.size}}

      true ->
        {parts, current, _used} = Enum.reduce(ordered, {[], [], 0}, &fill(&1, &2, room))
        {:ok, Enum.reverse([Enum.reverse(current) | parts])}
    end
  end

  # A resource to the part being filled, or to a new one when it is full.
  defp fill(entry, {parts, current, used}, room) do
    if used + entry.size > room and current != [],
      do: {[Enum.reverse(current) | parts], [entry], entry.size},
      else: {parts, [entry | current], used + entry.size}
  end

  defp write_parts(file, header, xml, parts, dir, name, progress) do
    count = length(parts)

    parts
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], progress}, fn {entries, number}, {:ok, paths, progress} ->
      path = Path.join(dir, if(number == 1, do: "#{name}.swm", else: "#{name}#{number}.swm"))

      case write_part(file, header, xml, entries, {number, count}, path, progress) do
        {:ok, progress} -> {:cont, {:ok, [path | paths], progress}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, paths, _progress} -> {:ok, Enum.reverse(paths)}
      error -> error
    end
  end

  defp write_part(file, header, xml, entries, {number, count}, path, progress) do
    with {:ok, out} <- File.open(path, [:write, :binary, :raw]) do
      try do
        with :ok <- IO.binwrite(out, :binary.copy(<<0>>, @header_size)),
             {:ok, moved, at, progress} <- copy_resources(file, out, entries, number, progress),
             table = Enum.map_join(moved, &entry_binary/1),
             :ok <- IO.binwrite(out, table),
             xml_at = at + byte_size(table),
             xml = total_bytes(xml, xml_at),
             :ok <- IO.binwrite(out, xml),
             :ok <-
               :file.pwrite(
                 out,
                 0,
                 part_header(header, moved, {number, count}, at, table, xml_at, xml)
               ) do
          {:ok, progress}
        end
      after
        File.close(out)
      end
    end
  end

  # Each resource to the part, raw; its entry with where it is now.
  defp copy_resources(file, out, entries, number, progress) do
    Enum.reduce_while(entries, {:ok, [], @header_size, progress}, fn entry,
                                                                     {:ok, moved, at, progress} ->
      case copy(file, out, entry.offset, entry.size, progress) do
        {:ok, progress} ->
          {:cont, {:ok, [%{entry | offset: at, part: number} | moved], at + entry.size, progress}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, moved, at, progress} -> {:ok, Enum.reverse(moved), at, progress}
      error -> error
    end
  end

  defp copy(_file, _out, _from, 0, progress), do: {:ok, progress}

  defp copy(file, out, from, left, {done, total, report}) do
    n = min(left, @chunk)

    with {:ok, data} when byte_size(data) == n <- :file.pread(file, from, n),
         :ok <- IO.binwrite(out, data) do
      report.(done + n, total)
      copy(file, out, from + n, left - n, {done + n, total, report})
    else
      {:ok, _short} -> {:error, :short_wim}
      :eof -> {:error, :short_wim}
      error -> error
    end
  end

  defp entry_binary(entry),
    do:
      reshdr_binary(entry) <> <<entry.part::little-16, entry.refs::little-32, entry.hash::binary>>

  defp part_header(header, moved, {number, count}, table_at, table, xml_at, xml) do
    table_hdr = %{
      header.table
      | offset: table_at,
        size: byte_size(table),
        original: byte_size(table)
    }

    xml_hdr = %{header.xml | offset: xml_at, size: byte_size(xml), original: byte_size(xml)}

    boot = if number == 1, do: boot_resource(header, moved), else: @empty_reshdr

    <<"MSWIM", 0, 0, 0, @header_size::little-32, header.version::little-32,
      header.flags ||| @flag_spanned::little-32, header.chunk::little-32, header.guid::binary,
      number::little-16, count::little-16, header.images::little-32,
      reshdr_binary(table_hdr)::binary, reshdr_binary(xml_hdr)::binary,
      reshdr_binary(boot)::binary, header.boot_index::little-32,
      reshdr_binary(@empty_reshdr)::binary, 0::size(60 * 8)>>
  end

  # The boot image's metadata resource, the boot index-th among them.
  defp boot_resource(%{boot_index: 0}, _moved), do: @empty_reshdr

  defp boot_resource(%{boot_index: index}, moved) do
    case moved |> Enum.filter(&((&1.flags &&& @resource_metadata) != 0)) |> Enum.at(index - 1) do
      nil -> @empty_reshdr
      entry -> Map.take(entry, [:size, :flags, :offset, :original])
    end
  end

  # The WIM's size before its XML data, the first TOTALBYTES.
  defp total_bytes(xml, at) do
    {bom, text} =
      case xml do
        <<0xFF, 0xFE, rest::binary>> -> {<<0xFF, 0xFE>>, rest}
        rest -> {"", rest}
      end

    case :unicode.characters_to_binary(text, {:utf16, :little}) do
      utf8 when is_binary(utf8) ->
        updated =
          Regex.replace(~r/<TOTALBYTES>\d+<\/TOTALBYTES>/, utf8, "<TOTALBYTES>#{at}</TOTALBYTES>",
            global: false
          )

        bom <> :unicode.characters_to_binary(updated, :utf8, {:utf16, :little})

      _invalid ->
        xml
    end
  end

  defp pread(file, offset, size) do
    case :file.pread(file, offset, size) do
      {:ok, data} when byte_size(data) == size -> {:ok, data}
      {:ok, _short} -> {:error, :short_wim}
      :eof -> {:error, :short_wim}
      error -> error
    end
  end
end
