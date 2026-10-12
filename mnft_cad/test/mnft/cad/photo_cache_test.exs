defmodule Mnft.Cad.PhotoCacheTest do
  use ExUnit.Case, async: false

  alias Mnft.Cad.PhotoCache

  defp sid(prefix), do: "#{prefix}-" <> Integer.to_string(System.unique_integer([:positive]))

  defp img(tag, bytes \\ <<1, 2, 3>>) do
    %{
      data_url: "data:image/png;base64," <> Base.encode64(bytes),
      media_type: "image/png",
      bytes: bytes,
      size: byte_size(bytes),
      label: "reference",
      tag: tag
    }
  end

  test "take misses return [], put/take round-trips, clear forgets" do
    id = sid("pc")

    assert PhotoCache.take(id) == []

    PhotoCache.put(id, [img(:a)])
    assert PhotoCache.take(id) == [img(:a)]

    PhotoCache.clear(id)
    assert PhotoCache.take(id) == []
  end

  test "newest set replaces the previous one" do
    id = sid("pc")

    PhotoCache.put(id, [img(:a)])
    PhotoCache.put(id, [img(:b), img(:c)])

    assert PhotoCache.take(id) == [img(:b), img(:c)]
  end

  test "an empty set never overwrites the cached row" do
    id = sid("pc")

    PhotoCache.put(id, [img(:a)])
    PhotoCache.put(id, [])

    assert PhotoCache.take(id) == [img(:a)]
  end

  test "eviction drops the oldest-touched sessions past the session cap" do
    first = "pc-evict-first-" <> Integer.to_string(System.unique_integer([:positive]))

    PhotoCache.put(first, [img(:old)])

    for i <- 1..130 do
      PhotoCache.put("pc-evict-#{i}-" <> Integer.to_string(System.unique_integer([:positive])), [
        img(i)
      ])
    end

    assert PhotoCache.take(first) == []

    newest = "pc-evict-newest-" <> Integer.to_string(System.unique_integer([:positive]))
    PhotoCache.put(newest, [img(:new)])
    assert PhotoCache.take(newest) == [img(:new)]
  end
end
