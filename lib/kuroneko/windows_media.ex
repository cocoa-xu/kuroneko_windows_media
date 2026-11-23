defmodule Kuroneko.WindowsMedia do
  @moduledoc """
  Windows installer USB drives for Kuroneko's virtual disk: a maker
  (`Kuroneko.VirtualDisk.Maker`) that offers, for a Windows installer's
  ISO, a USB drive the target computer starts with UEFI, Secure Boot on or
  off (`Kuroneko.WindowsMedia.Drive`).

  Kuroneko's optical drive already starts the ISO itself, with a BIOS or
  UEFI. The USB drive is for a computer that will not start from an optical
  drive, or a Windows Setup that should see the files on a USB drive.

  Add it to Kuroneko's dependencies and makers,

      {:kuroneko_windows_media, github: "cocoa-xu/kuroneko_windows_media", tag: "v0.1.0"}

      config :kuroneko, disk_makers: [Kuroneko.WindowsMedia]

  or register it at run time, from IEx for instance:

      Kuroneko.VirtualDisk.register_maker(Kuroneko.WindowsMedia)

  This library is GPL-3.0-or-later: a firmware that has it carries the
  GPL's terms for it.
  """

  alias Kuroneko.WindowsMedia.Drive

  @typedoc """
  An item of Kuroneko's library: an image file or a folder, with what
  Kuroneko read of an image (`nil` for a folder). Of an image, the maker
  reads its UDF revision, its boot platforms and its label.
  """
  @type item() :: %{path: Path.t(), kind: :image | :folder, format: map() | nil}

  @typedoc """
  What Kuroneko gives `make/3`: where to make the image, a function told
  the bytes done and their total, and the bytes free for the image.
  """
  @type context() :: %{image: Path.t(), progress: progress(), free: non_neg_integer()}

  @typedoc "A function told the bytes done and their total, as they go."
  @type progress() :: (done :: non_neg_integer(), total :: non_neg_integer() -> any())

  @doc "The maker's id: `\"windows-media\"`."
  @spec id() :: String.t()
  def id, do: "windows-media"

  @doc """
  A USB drive for an image with UDF and a UEFI boot entry, as Windows
  installers have; whether it is one is checked when the drive is made.
  """
  @spec offers(item()) :: [%{mode: String.t(), label: String.t()}]
  def offers(%{kind: :image, format: %{udf: udf, boot: boot}}) when is_binary(udf) do
    if :uefi in boot,
      do: [%{mode: "uefi", label: "USB drive: Windows installer, UEFI"}],
      else: []
  end

  def offers(_item), do: []

  @doc "Makes the USB drive's image of an item it offered one for; it goes in read-only."
  @spec make(item(), String.t(), context()) ::
          {:ok, [cdrom: false, read_only: true]} | {:error, term()}
  def make(%{path: iso, format: %{label: label}}, "uefi", context) do
    %{image: image, progress: progress, free: free} = context

    with :ok <- Drive.make(iso, image, label: label, free: free, progress: progress),
         do: {:ok, cdrom: false, read_only: true}
  end
end
