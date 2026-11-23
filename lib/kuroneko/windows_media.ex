defmodule Kuroneko.WindowsMedia do
  @moduledoc """
  Windows installer USB drives for Kuroneko's virtual disk: a maker that
  offers, for a Windows installer's ISO, a USB drive the target computer
  starts with UEFI, Secure Boot on or off (`Kuroneko.WindowsMedia.Drive`).

  Kuroneko's optical drive already starts the ISO itself, with a BIOS or
  UEFI. The USB drive is for a computer that will not start from an optical
  drive, or a Windows Setup that should see the files on a USB drive.

  ## The maker

  A maker is a module with three functions, which Kuroneko takes from its
  `:disk_makers` setting, or registered at run time:

    * `id/0` - the maker's id
    * `offers/1` - what it offers for an item of Kuroneko's library, which
      Kuroneko lists with the item
    * `make/3` - makes the image of an item for an offer that is picked,
      in a task of Kuroneko's, given a `t:context/0` that brings Kuroneko's
      FAT32 formatter, and says how the image goes in the drive

  This maker needs the Kuroneko release after v0.1.2, whose makers get
  that context.

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
  the bytes done and their total, the bytes free for the image, and
  Kuroneko's FAT32 formatter.
  """
  @type context() :: %{
          image: Path.t(),
          progress: progress(),
          free: non_neg_integer(),
          format_fat: format_fat()
        }

  @typedoc "A function told the bytes done and their total, as they go."
  @type progress() :: (done :: non_neg_integer(), total :: non_neg_integer() -> any())

  @typedoc """
  Makes an empty FAT32 file system of `size` bytes in the file at `path`,
  named `:label`, from `:offset` in the file.
  """
  @type format_fat() ::
          (path :: Path.t(),
           size :: pos_integer(),
           opts :: [label: String.t(), offset: non_neg_integer()] ->
             :ok | {:error, term()})

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

  @doc """
  Makes the USB drive's image of an item it offered one for; it goes in as
  a read-only disk.
  """
  @spec make(item(), String.t(), context()) ::
          {:ok, [as: :disk, read_only: true]} | {:error, term()}
  def make(%{path: iso, format: %{label: label}}, "uefi", context) do
    %{image: image, progress: progress, free: free, format_fat: format_fat} = context
    opts = [format_fat: format_fat, label: label, free: free, progress: progress]

    with :ok <- Drive.make(iso, image, opts), do: {:ok, as: :disk, read_only: true}
  end
end
