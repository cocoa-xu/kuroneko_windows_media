defmodule Kuroneko.WindowsMediaTest do
  use ExUnit.Case, async: true

  alias Kuroneko.WindowsMedia

  test "a USB drive for an ISO with UDF and a UEFI boot entry" do
    windows = %{
      path: "win.iso",
      kind: :image,
      format: %{udf: "1.02", boot: [:bios, :uefi], label: "CCCOMA_X64FRE_EN-US_DV9"}
    }

    assert WindowsMedia.offers(windows) == [
             %{mode: "uefi", label: "USB drive: Windows installer, UEFI"}
           ]

    assert WindowsMedia.offers(put_in(windows.format.boot, [:bios])) == []
    assert WindowsMedia.offers(put_in(windows.format.udf, nil)) == []
    assert WindowsMedia.offers(%{path: "x", kind: :folder, format: nil}) == []
    assert WindowsMedia.id() == "windows-media"
  end
end
