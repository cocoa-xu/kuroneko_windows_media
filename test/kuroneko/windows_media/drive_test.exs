defmodule Kuroneko.WindowsMedia.DriveTest do
  use ExUnit.Case, async: true

  alias Kuroneko.WindowsMedia.Drive

  @moduletag :tmp_dir

  test "an ISO that does not mount leaves nothing behind", %{tmp_dir: dir} do
    iso = Path.join(dir, "not.iso")
    File.write!(iso, "not an ISO")

    format_fat = fn _path, _size, _opts ->
      flunk("formatted a drive for an ISO it did not mount")
    end

    assert {:error, {"mount", _reason}} =
             Drive.make(iso, Path.join(dir, "drive.img"), format_fat: format_fat)

    assert File.ls!(dir) == ["not.iso"]
  end
end
