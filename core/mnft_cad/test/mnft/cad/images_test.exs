defmodule Mnft.Cad.ImagesTest do
  use ExUnit.Case, async: true

  alias Mnft.Cad.Images

  defp b64(n) when is_integer(n), do: Base.encode64(:binary.copy(<<?0>>, n))
  defp png_data_url, do: "data:image/png;base64," <> Base.encode64("\x89PNG ok")

  describe "validate/1 happy paths" do
    test "valid png/jpeg/webp pass with metadata" do
      urls = [
        "data:image/png;base64,#{b64(10)}",
        "data:image/jpeg;base64,#{b64(10)}",
        "data:image/webp;base64,#{b64(10)}"
      ]

      {:ok, out} = Images.validate(Enum.map(urls, &%{data_url: &1, label: "reference"}))
      assert length(out) == 3
      assert hd(out).data_url == hd(urls)
      assert hd(out).media_type == "image/png"
      assert hd(out).label == "reference"
      assert hd(out).size == 10
    end

    test "current label passes through" do
      {:ok, out} = Images.validate([%{data_url: png_data_url(), label: "current"}])
      assert hd(out).label == "current"
    end

    test "no images means empty list" do
      assert Images.validate(nil) == {:ok, []}
      assert Images.validate([]) == {:ok, []}
    end
  end

  describe "validate/1 rejections" do
    test "gif rejected with clear message" do
      url = "data:image/gif;base64," <> Base.encode64("GIF89a")
      assert {:error, e} = Images.validate([%{data_url: url, label: "reference"}])
      assert e =~ "images[0]: unsupported media type image/gif"
    end

    test "non-data-url rejected" do
      assert {:error, e} = Images.validate([%{data_url: "https://x/y.png", label: "reference"}])
      assert e =~ "images[0]" and e =~ "data:image"
    end

    test "data url without base64 rejected" do
      assert {:error, e} =
               Images.validate([%{data_url: "data:image/png,png", label: "reference"}])

      assert e =~ "images[0]" and e =~ "base64-encoded"
    end

    test "bad base64 characters rejected" do
      assert {:error, e} =
               Images.validate([%{data_url: "data:image/png;base64,@@@!", label: "reference"}])

      assert e =~ "not valid base64"
    end

    test "oversize single image rejected" do
      url = "data:image/png;base64," <> b64(4 * 1024 * 1024 + 1)
      assert {:error, e} = Images.validate([%{data_url: url, label: "reference"}])
      assert e =~ "images[0]" and e =~ "per-image"
    end

    test "total limit rejected across images" do
      url = "data:image/jpeg;base64," <> b64(3 * 1024 * 1024)

      assert {:error, e} =
               Images.validate([
                 %{data_url: url, label: "reference"},
                 %{data_url: url, label: "reference"},
                 %{data_url: url, label: "reference"}
               ])

      assert e =~ "per-turn"
    end

    test "more than three images rejected" do
      imgs = for _ <- 1..4, do: %{data_url: png_data_url(), label: "reference"}
      assert {:error, e} = Images.validate(imgs)
      assert e =~ "limit is 3"
    end
  end

  describe "thumbnail/1" do
    test "valid data URL under the size cap passes through" do
      thumb = "data:image/jpeg;base64," <> Base.encode64("jpeg")
      assert Images.thumbnail(%{"thumb" => thumb}) == thumb
      assert Images.thumbnail(%{thumb: thumb}) == thumb
    end

    test "oversized, malformed, and missing thumbs return nil" do
      huge = "data:image/jpeg;base64," <> Base.encode64(:binary.copy(<<?0>>, 64 * 1024 + 1))
      assert Images.thumbnail(%{"thumb" => huge}) == nil
      assert Images.thumbnail(%{"thumb" => "javascript:alert(1)"}) == nil

      assert Images.thumbnail(%{"thumb" => "data:image/gif;base64," <> Base.encode64("GIF")}) ==
               nil

      assert Images.thumbnail(%{"thumb" => 123}) == nil
      assert Images.thumbnail(%{}) == nil
      assert Images.thumbnail(nil) == nil
    end

    test "validate keeps the sanitized thumb on the entry" do
      thumb = "data:image/jpeg;base64," <> Base.encode64("jpeg")

      assert {:ok, [entry]} =
               Images.validate([%{data_url: png_data_url(), label: "reference", thumb: thumb}])

      assert entry.thumb == thumb
    end
  end
end
