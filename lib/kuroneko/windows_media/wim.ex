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

  @empty_reshdr %{size: 0, flags: 0, offset: 0, original: 0}

  @typep reshdr() :: %{
           size: non_neg_integer(),
           flags: byte(),
           offset: non_neg_integer(),
           original: non_neg_integer()
         }

  @typep header() :: %{
           version: non_neg_integer(),
           flags: non_neg_integer(),
           chunk: non_neg_integer(),
           guid: <<_::128>>,
           part: non_neg_integer(),
           parts: non_neg_integer(),
           images: non_neg_integer(),
           table: reshdr(),
           xml: reshdr(),
           boot: reshdr(),
           boot_index: non_neg_integer(),
           integrity: reshdr()
         }

  @typep entry() :: %{
           size: non_neg_integer(),
           flags: byte(),
           offset: non_neg_integer(),
           original: non_neg_integer(),
           part: non_neg_integer(),
           refs: non_neg_integer(),
           hash: <<_::160>>
         }

  @doc """
  Splits the WIM at `source` into parts in `dir`, and gives their paths.

  Options:

    * `:max_bytes` (required) - the size no part is larger than
    * `:name` - what the parts are named after: `"install"` gives
      `install.swm`, `install2.swm` and so on. Defaults to the name of
      `source` without its extension
    * `:progress` - a `t:Kuroneko.WindowsMedia.progress/0`, told the bytes
      of resources copied and their total

  A file that is not a WIM gives `{:error, :not_a_wim}`, a solid WIM
  `{:error, :solid}`, a split one `{:error, :already_split}`, and one with a
  resource larger than a part can hold `{:error, {:resource_too_large, size}}`.
  """
  @spec split(Path.t(), Path.t(), keyword()) :: {:ok, [Path.t(), ...]} | {:error, term()}
  def split(source, dir, opts) do
    opts =
      Keyword.validate!(opts, [
        :max_bytes,
        name: Path.rootname(Path.basename(source)),
        progress: fn _done, _total -> :ok end
      ])

    max_bytes = Keyword.fetch!(opts, :max_bytes)

    with_file(source, [:read, :binary, :raw], fn file ->
      with {:ok, header} <- read_header(file),
           :ok <- not_split(header),
           {:ok, entries} <- read_table(file, header.table),
           :ok <- not_solid(entries),
           {:ok, xml} <- pread(file, header.xml.offset, header.xml.size),
           {:ok, groups} <- assign(entries, max_bytes - overhead(entries, xml)) do
        total = entries |> Enum.map(& &1.size) |> Enum.sum()
        context = %{file: file, header: header, xml: xml, progress: opts[:progress], total: total}
        write_parts(parts(groups, dir, opts[:name]), context, 0)
      end
    end)
  end

  @spec read_header(:file.io_device()) :: {:ok, header()} | {:error, term()}
  defp read_header(file) do
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

      {:error, _reason} = error ->
        error
    end
  end

  defp header_binary(header) do
    <<"MSWIM", 0, 0, 0, @header_size::little-32, header.version::little-32,
      header.flags::little-32, header.chunk::little-32, header.guid::binary,
      header.part::little-16, header.parts::little-16, header.images::little-32,
      reshdr_binary(header.table)::binary, reshdr_binary(header.xml)::binary,
      reshdr_binary(header.boot)::binary, header.boot_index::little-32,
      reshdr_binary(header.integrity)::binary, 0::size(60)-unit(8)>>
  end

  defp reshdr(<<size::little-56, flags, offset::little-64, original::little-64>>),
    do: %{size: size, flags: flags, offset: offset, original: original}

  defp reshdr_binary(%{size: size, flags: flags, offset: offset, original: original}),
    do: <<size::little-56, flags, offset::little-64, original::little-64>>

  defp not_split(%{parts: 1}), do: :ok
  defp not_split(%{parts: _parts}), do: {:error, :already_split}

  @spec read_table(:file.io_device(), reshdr()) :: {:ok, [entry()]} | {:error, term()}
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

  defp entry_binary(entry),
    do:
      reshdr_binary(entry) <> <<entry.part::little-16, entry.refs::little-32, entry.hash::binary>>

  defp not_solid(entries) do
    if Enum.any?(entries, &((&1.flags &&& @resource_solid) != 0)),
      do: {:error, :solid},
      else: :ok
  end

  # The header, the lookup table and the XML data a part holds besides its
  # resources, at most: the XML may grow by a few digits.
  defp overhead(entries, xml),
    do: @header_size + length(entries) * @entry_size + byte_size(xml) + 64

  @spec assign([entry()], integer()) ::
          {:ok, [[entry()], ...]}
          | {:error, :part_too_small | {:resource_too_large, non_neg_integer()}}
  defp assign(entries, room) do
    {metadata, others} = Enum.split_with(entries, &((&1.flags &&& @resource_metadata) != 0))
    # The metadata keeps the table's order, which is the images' order.
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

  defp fill(entry, {parts, current, used}, room) do
    if used + entry.size > room and current != [],
      do: {[Enum.reverse(current) | parts], [entry], entry.size},
      else: {parts, [entry | current], used + entry.size}
  end

  defp parts(groups, dir, name) do
    count = length(groups)

    for {entries, number} <- Enum.with_index(groups, 1) do
      file = if number == 1, do: "#{name}.swm", else: "#{name}#{number}.swm"
      %{number: number, count: count, path: Path.join(dir, file), entries: entries}
    end
  end

  defp write_parts([], _context, _done), do: {:ok, []}

  defp write_parts([part | parts], context, done) do
    with {:ok, done} <- write_part(part, context, done),
         {:ok, paths} <- write_parts(parts, context, done),
         do: {:ok, [part.path | paths]}
  end

  defp write_part(part, context, done) do
    {header, trailer} = header_and_trailer(part, context)

    with_file(part.path, [:write, :binary, :raw], fn out ->
      with :ok <- IO.binwrite(out, <<0::size(@header_size)-unit(8)>>),
           {:ok, done} <- copy_resources(part.entries, context, out, done),
           :ok <- IO.binwrite(out, trailer),
           :ok <- :file.pwrite(out, 0, header),
           do: {:ok, done}
    end)
  end

  defp header_and_trailer(part, %{header: header, xml: xml}) do
    {moved, table_at} =
      Enum.map_reduce(part.entries, @header_size, fn entry, at ->
        {%{entry | offset: at, part: part.number}, at + entry.size}
      end)

    table = Enum.map_join(moved, &entry_binary/1)
    xml_at = table_at + byte_size(table)
    xml = put_total_bytes(xml, xml_at)

    header = %{
      header
      | flags: header.flags ||| @flag_spanned,
        part: part.number,
        parts: part.count,
        table: placed(header.table, table_at, table),
        xml: placed(header.xml, xml_at, xml),
        boot: boot(header, part, moved),
        integrity: @empty_reshdr
    }

    {header_binary(header), [table, xml]}
  end

  defp placed(reshdr, offset, data),
    do: %{reshdr | offset: offset, size: byte_size(data), original: byte_size(data)}

  defp boot(%{boot_index: index}, %{number: 1}, moved) when index > 0 do
    case moved |> Enum.filter(&((&1.flags &&& @resource_metadata) != 0)) |> Enum.at(index - 1) do
      nil -> @empty_reshdr
      entry -> Map.take(entry, [:size, :flags, :offset, :original])
    end
  end

  defp boot(_header, _part, _moved), do: @empty_reshdr

  defp copy_resources([], _context, _out, done), do: {:ok, done}

  defp copy_resources([entry | entries], context, out, done) do
    with {:ok, done} <- copy(context, out, entry.offset, entry.size, done),
         do: copy_resources(entries, context, out, done)
  end

  defp copy(_context, _out, _from, 0, done), do: {:ok, done}

  defp copy(context, out, from, left, done) do
    n = min(left, @chunk)

    with {:ok, data} <- pread(context.file, from, n),
         :ok <- IO.binwrite(out, data) do
      context.progress.(done + n, context.total)
      copy(context, out, from + n, left - n, done + n)
    end
  end

  # The WIM's size before its XML data is the first TOTALBYTES; the images'
  # own come after it.
  defp put_total_bytes(xml, at) do
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
      {:error, _reason} = error -> error
    end
  end

  defp with_file(path, modes, fun) do
    with {:ok, result} <- File.open(path, modes, fun), do: result
  end
end
