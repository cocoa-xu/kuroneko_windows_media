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

  @doc "The maker's id: `\"windows-media\"`."
  @spec id() :: String.t()
  def id, do: "windows-media"

  @doc """
  A USB drive for an ISO with UDF and a UEFI boot entry, as Windows
  installers have; whether it is one is checked when the drive is made.
  """
  @spec offers(map()) :: [%{mode: String.t(), label: String.t()}]
  def offers(%{kind: :image, format: %{udf: udf, boot: boot}})
      when is_binary(udf) and is_list(boot) do
    if :uefi in boot,
      do: [%{mode: "uefi", label: "USB drive: Windows installer, UEFI"}],
      else: []
  end

  def offers(_item), do: []

  @doc "Makes the USB drive's image; it goes in read-only."
  @spec make(map(), String.t(), map()) :: {:ok, keyword()} | {:error, term()}
  def make(%{path: iso} = item, "uefi", %{image: image, progress: progress} = context) do
    opts = [progress: progress, free: context[:free], label: get_in(item, [:format, :label])]

    with :ok <- Drive.make(iso, image, opts),
         do: {:ok, cdrom: false, read_only: true}
  end

  def make(_item, mode, _context), do: {:error, {:unknown_mode, mode}}
end
