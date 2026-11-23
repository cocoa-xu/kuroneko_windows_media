defmodule Kuroneko.WindowsMedia.WIMTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Kuroneko.WindowsMedia.WIM

  @moduletag :tmp_dir

  @guid <<1::128>>

  defp reshdr(size, flags, offset, original),
    do: <<size::little-56, flags, offset::little-64, original::little-64>>

  # A WIM of two images: their metadata, then resources of 100 kB, some of
  # them compressed, the lookup table and the XML data.
  defp wim(path, opts \\ []) do
    resource_flags = Keyword.get(opts, :resource_flags, 0x4)
    parts = Keyword.get(opts, :parts, 1)
    boot_index = Keyword.get(opts, :boot_index, 0)

    resources =
      [{0x6, :crypto.strong_rand_bytes(3000)}, {0x6, :crypto.strong_rand_bytes(5000)}] ++
        for(
          i <- 1..7,
          do:
            {if(rem(i, 2) == 0, do: 0, else: resource_flags), :crypto.strong_rand_bytes(100_000)}
        )

    {entries, data, at} =
      Enum.reduce(resources, {[], <<>>, 208}, fn {flags, bytes}, {entries, data, at} ->
        hash = :crypto.hash(:sha, bytes)

        entry =
          reshdr(byte_size(bytes), flags, at, byte_size(bytes) * 2) <>
            <<1::little-16, 1::little-32, hash::binary>>

        {[entry | entries], data <> bytes, at + byte_size(bytes)}
      end)

    table = entries |> Enum.reverse() |> IO.iodata_to_binary()
    xml_at = at + byte_size(table)

    xml =
      <<0xFF, 0xFE>> <>
        :unicode.characters_to_binary(
          "<WIM><TOTALBYTES>#{xml_at}</TOTALBYTES><IMAGE INDEX=\"1\"><TOTALBYTES>9</TOTALBYTES></IMAGE></WIM>",
          :utf8,
          {:utf16, :little}
        )

    header =
      <<"MSWIM", 0, 0, 0, 208::little-32, 0x10D00::little-32, 0x40082::little-32,
        32_768::little-32, @guid::binary, 1::little-16, parts::little-16, 2::little-32,
        reshdr(byte_size(table), 0x2, at, byte_size(table))::binary,
        reshdr(byte_size(xml), 0x2, xml_at, byte_size(xml))::binary, reshdr(0, 0, 0, 0)::binary,
        boot_index::little-32, reshdr(0, 0, 0, 0)::binary, 0::size(60 * 8)>>

    File.write!(path, header <> data <> table <> xml)
    resources
  end

  defp part(path) do
    wim = File.read!(path)

    <<"MSWIM", 0, 0, 0, 208::little-32, _version::little-32, flags::little-32, _chunk::little-32,
      guid::binary-size(16), number::little-16, count::little-16, images::little-32,
      table_size::little-56, _table_flags, table_at::little-64, _table_original::little-64,
      xml_size::little-56, _xml_flags, xml_at::little-64, _xml_original::little-64,
      boot::binary-size(24), _rest::binary>> = wim

    entries =
      for <<size::little-56, flags, offset::little-64, _original::little-64, part::little-16,
            refs::little-32, hash::binary-size(20) <- binary_part(wim, table_at, table_size)>> do
        bytes = binary_part(wim, offset, size)
        %{flags: flags, offset: offset, part: part, refs: refs, hash: hash, bytes: bytes}
      end

    <<0xFF, 0xFE, xml::binary>> = binary_part(wim, xml_at, xml_size)

    %{
      flags: flags,
      guid: guid,
      number: number,
      count: count,
      images: images,
      boot: boot,
      entries: entries,
      xml_at: xml_at,
      xml: :unicode.characters_to_binary(xml, {:utf16, :little})
    }
  end

  test "splits a WIM into parts no larger than asked, resources as they were", %{tmp_dir: dir} do
    source = Path.join(dir, "install.wim")
    resources = wim(source, boot_index: 2)
    pid = self()

    assert {:ok, paths} =
             WIM.split(source, dir,
               max_bytes: 260_000,
               progress: &send(pid, {:progress, &1, &2})
             )

    assert Enum.map(paths, &Path.basename/1) == [
             "install.swm",
             "install2.swm",
             "install3.swm",
             "install4.swm"
           ]

    assert Enum.all?(paths, &(File.stat!(&1).size <= 260_000))

    parts = Enum.map(paths, &part/1)

    for {part, number} <- Enum.with_index(parts, 1) do
      assert %{number: ^number, count: 4, guid: @guid, images: 2} = part
      assert (part.flags &&& 0x8) == 0x8
      assert Enum.all?(part.entries, &(&1.part == number))
      assert part.xml =~ "<WIM><TOTALBYTES>#{part.xml_at}</TOTALBYTES>"
      assert part.xml =~ "<TOTALBYTES>9</TOTALBYTES></IMAGE>"
    end

    # The metadata first, in the first part, in the order of the images; the
    # boot image is the second.
    [first | others] = parts
    assert [%{flags: 0x6} = one, %{flags: 0x6} = two | _blobs] = first.entries
    assert [one.bytes, two.bytes] == Enum.map(Enum.take(resources, 2), &elem(&1, 1))
    assert first.boot == reshdr(5000, 0x6, two.offset, 10_000)
    assert Enum.all?(others, &(&1.boot == reshdr(0, 0, 0, 0)))

    # Every resource once, its bytes and hash as they were.
    copied = Enum.flat_map(parts, & &1.entries)

    assert Enum.map(copied, & &1.bytes) |> Enum.sort() ==
             Enum.map(resources, &elem(&1, 1)) |> Enum.sort()

    assert Enum.all?(copied, &(&1.hash == :crypto.hash(:sha, &1.bytes) and &1.refs == 1))

    assert_received {:progress, 708_000, 708_000}
  end

  test "names the parts after :name", %{tmp_dir: dir} do
    source = Path.join(dir, "install.wim")
    wim(source)

    assert {:ok, [path]} = WIM.split(source, dir, max_bytes: 1_000_000, name: "sources")
    assert Path.basename(path) == "sources.swm"
    assert %{number: 1, count: 1} = part(path)
  end

  test "WIMs it does not split", %{tmp_dir: dir} do
    solid = Path.join(dir, "solid.wim")
    wim(solid, resource_flags: 0x14)
    assert WIM.split(solid, dir, max_bytes: 260_000) == {:error, :solid}

    spanned = Path.join(dir, "spanned.wim")
    wim(spanned, parts: 2)
    assert WIM.split(spanned, dir, max_bytes: 260_000) == {:error, :already_split}

    whole = Path.join(dir, "whole.wim")
    wim(whole)
    assert WIM.split(whole, dir, max_bytes: 100_500) == {:error, {:resource_too_large, 100_000}}

    text = Path.join(dir, "text.wim")
    File.write!(text, :binary.copy("x", 300))
    assert WIM.split(text, dir, max_bytes: 260_000) == {:error, :not_a_wim}
  end
end
