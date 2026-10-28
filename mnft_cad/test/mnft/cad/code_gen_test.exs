defmodule Mnft.Cad.CodeGenTest do
  use ExUnit.Case, async: true

  alias Mnft.Cad.CodeGen

  describe "extract_code/1" do
    test "returns the last python block" do
      text = """
      Here is one:
      ```python
      part = Box(1, 1, 1)
      ```
      And a better one:
      ```python
      part = Box(2, 2, 2)
      ```
      """

      assert CodeGen.extract_code(text) == "part = Box(2, 2, 2)"
    end

    test "no block returns nil" do
      assert CodeGen.extract_code("just words, no code") == nil
      assert CodeGen.extract_code("") == nil
      assert CodeGen.extract_code(nil) == nil
    end

    test "handles py tag and bare fence" do
      assert CodeGen.extract_code("```py\nx = 1\n```") == "x = 1"
      assert CodeGen.extract_code("```\nx = 1\n```") == "x = 1"
    end

    test "reads scad/openscad-tagged fences (OpenSCAD dialect)" do
      assert CodeGen.extract_code("```scad\ncube(1);\n```") == "cube(1);"

      assert CodeGen.extract_code("Recapping:\n```openscad\ncube([2, 3, 4]);\n```") ==
               "cube([2, 3, 4]);"
    end

    test "skips empty blocks" do
      assert CodeGen.extract_code("```python\n   \n```") == nil

      assert CodeGen.extract_code("```python\n\n```\n```python\npart = Box(1,1,1)\n```") ==
               "part = Box(1,1,1)"
    end

    test "is not fooled by an unclosed fence" do
      assert CodeGen.extract_code("```python\npart = Box(1, 1, 1)") == nil
    end
  end

  describe "strip_code_blocks/1" do
    test "replaces complete tagged and bare fences, keeps the prose" do
      text = """
      Here is one:
      ```python
      part = Box(1, 1, 1)
      ```
      And a better one:
      ```
      part = Box(2, 2, 2)
      ```
      """

      stripped = CodeGen.strip_code_blocks(text)

      refute stripped =~ "part = Box"
      refute stripped =~ "```"
      assert stripped =~ "Here is one:"
      assert stripped =~ "And a better one:"

      assert String.split(stripped, "[earlier code elided]") |> length() == 3
    end

    test "leaves an unterminated fence untouched" do
      text = "cut off:\n```python\npart = Box(1, 1"
      assert CodeGen.strip_code_blocks(text) == text
    end

    test "trims the result" do
      assert CodeGen.strip_code_blocks("\n\n```python\nx = 1\n```\n\n") == "[earlier code elided]"
    end
  end

  describe "truncation_reason/2" do
    test "finish_reason length (string or atom, any case)" do
      assert CodeGen.truncation_reason("```python\npart = Box(1, 1, 1)", "length") != nil
      assert CodeGen.truncation_reason("just prose", "length") != nil
      assert CodeGen.truncation_reason("just prose", "LENGTH") != nil
      assert CodeGen.truncation_reason("just prose", :length) != nil
    end

    test "unbalanced fences" do
      assert CodeGen.truncation_reason("here you go:\n```python\npart = Box(1, 1, 1)", "stop")
      assert CodeGen.truncation_reason("part = Box(1)\n```", nil)
    end

    test "no false positives" do
      assert CodeGen.truncation_reason("A screw is a fastener with a helical ridge.", "stop") ==
               nil

      assert CodeGen.truncation_reason("prose only", nil) == nil
      assert CodeGen.truncation_reason("prose with ```closed``` fence", "stop") == nil
    end
  end

  describe "partial_code/1" do
    test "recovers the unclosed block" do
      assert CodeGen.partial_code("Here's the screw:\n```python\npart = Box(1, 1\n") ==
               "part = Box(1, 1"

      assert CodeGen.partial_code("```python\npart = Box(1, 1\n") == "part = Box(1, 1"
      assert CodeGen.partial_code("```py\npart = Box(1, 1\n") == "part = Box(1, 1"
    end

    test "none cases" do
      assert CodeGen.partial_code("no fences at all") == nil
      assert CodeGen.partial_code("") == nil
      assert CodeGen.partial_code(nil) == nil
    end
  end

  describe "repair messages" do
    test "repair message carries tail of error and the code" do
      msg = CodeGen.build_repair_message("part = Box(1, 1, 1)", "RuntimeError: boom")

      assert String.starts_with?(msg, "Your build123d code failed.")
      assert msg =~ "RuntimeError: boom"
      assert msg =~ "```python\npart = Box(1, 1, 1)\n```"
      assert msg =~ "corrected, complete ```python block"
      refute msg =~ "\n\n\n"
    end

    test "repair message with no error falls back" do
      assert CodeGen.build_repair_message("x", nil) =~ "unknown error"
    end

    test "truncated repair message includes the partial when present" do
      with_partial = CodeGen.build_truncated_repair_message("part = Box(1, 1")
      assert with_partial =~ "What you managed to output:"
      assert with_partial =~ "part = Box(1, 1"
      assert with_partial =~ "Return the complete script this time"

      without = CodeGen.build_truncated_repair_message(nil)
      refute without =~ "What you managed to output:"
      assert without =~ "Return the complete script this time"
    end
  end

  describe "current_model_line/1" do
    test "formats like the PoC (%g: trailing zeros stripped)" do
      current = %{"bbox_mm" => [30.0, 30.0, 30.0], "triangles" => 220, "volume_mm3" => 27_000.0}

      assert CodeGen.current_model_line(current) ==
               "Current model: bbox 30 x 30 x 30 mm, 220 triangles, volume 27000 mm3."
    end

    test "keeps significant decimals" do
      current = %{"bbox_mm" => [46.188, 40.0, 100.0], "triangles" => 12, "volume_mm3" => 1_234.5}

      assert CodeGen.current_model_line(current) ==
               "Current model: bbox 46.188 x 40 x 100 mm, 12 triangles, volume 1234.5 mm3."
    end

    test "engines without mesh figures yield no line instead of crashing" do
      current = %{"bbox_mm" => nil, "triangles" => nil, "volume_mm3" => nil}

      assert CodeGen.current_model_line(current) == nil
      assert CodeGen.build_user_content("make it taller", [], current) == "make it taller"
    end
  end

  describe "build_user_content/3" do
    test "text-only stays a plain string" do
      assert CodeGen.build_user_content("  make a cube  ", [], nil) == "make a cube"
    end

    test "empty-map current is treated as no model (client default)" do
      assert CodeGen.build_user_content("make a cube", [], %{}) == "make a cube"

      assert CodeGen.build_user_content(
               "make a cube",
               [%{data_url: "u", label: "reference"}],
               %{}
             )
             |> length() == 3
    end

    test "text-only with current appends the numbers line" do
      current = %{
        "bbox_mm" => [29.8731, 30.0, 60.0],
        "triangles" => 220,
        "volume_mm3" => 50_000.5
      }

      content = CodeGen.build_user_content("make it taller", [], current)
      assert content =~ "\n\nCurrent model: bbox 29.8731 x 30 x 60 mm, 220 triangles"
    end

    test "images become labeled parts in order" do
      url = "data:image/png;base64," <> Base.encode64("pngbytes")

      parts =
        CodeGen.build_user_content("model this", [%{data_url: url, label: "reference"}], nil)

      assert [%{type: :text, text: "model this"}, %{type: :text, text: label}, img] = parts
      assert label == "Reference photo from the user:"
      assert img.type == :image_url
      assert img.data_url == url
    end

    test "current label is used for current-labeled images" do
      parts = CodeGen.build_user_content("fix it", [%{data_url: "u", label: "current"}], nil)
      assert Enum.at(parts, 1).text =~ "Our current model, rendered"
    end

    test "current numbers appended after images" do
      current = %{"bbox_mm" => [30.0, 30.0, 30.0], "triangles" => 220, "volume_mm3" => 27_000.0}

      parts =
        CodeGen.build_user_content("compare", [%{data_url: "u", label: "reference"}], current)

      assert List.last(parts).text == CodeGen.current_model_line(current)
    end
  end

  describe "replicad dialect (browser)" do
    test "extract_code returns the js-tagged block" do
      text = "Here you go.\n\n```js\nconst part = sketchCircle(5).extrude(10);\n```\n"

      assert CodeGen.extract_code(text) == "const part = sketchCircle(5).extrude(10);"
    end

    test "extract_code handles the javascript tag and last-block-wins" do
      text = "```javascript\nconst a = 1;\n```\nmid\n```javascript\nconst part = a;\n```"

      assert CodeGen.extract_code(text) == "const part = a;"
    end

    test "extract_code still prefers a python-tagged block when both exist" do
      text = "```js\nconst x = 1;\n```\n```python\npart = Box(1)\n```"

      assert CodeGen.extract_code(text) == "part = Box(1)"
    end

    test "extract_code is not fooled by an unclosed js fence" do
      assert CodeGen.extract_code("```js\nconst part = sketchCircle(5)") == nil
    end

    test "partial_code recovers an unterminated js fence" do
      text = "```js\nconst part = sketchCircle(5).extrude(10);"

      assert CodeGen.partial_code(text) == "const part = sketchCircle(5).extrude(10);"
    end

    test "build_repair_message(:replicad, ...) fences the old code as js" do
      msg = CodeGen.build_repair_message(:replicad, "const part = bad();", "SyntaxError: nope")

      assert msg =~ "```js"
      assert msg =~ "const part = bad();"
      assert msg =~ "SyntaxError: nope"
      assert msg =~ "translate()"
      assert msg =~ "measureShapeVolumeProperties"
    end

    test "build_truncated_repair_message(:replicad, ...) asks for one complete js block" do
      msg = CodeGen.build_truncated_repair_message(:replicad, "const part = sketchCir")

      assert msg =~ "```js"
      assert msg =~ "under 60 lines"
      assert msg =~ "const part = sketchCir"
    end

    test "build_truncated_repair_message(:replicad, nil) still fences js" do
      assert CodeGen.build_truncated_repair_message(:replicad, nil) =~ "```js"
    end

    test "build_noop_message(:replicad, ...) asks for one complete js block" do
      msg =
        CodeGen.build_noop_message(
          :replicad,
          "make it taller",
          "bbox 40 x 40 x 90 mm, 44 triangles, 37600 mm3"
        )

      assert msg =~ "```js"
      assert msg =~ "make it taller"
      assert msg =~ "bbox 40 x 40 x 90 mm"
    end
  end

  describe "redaction + summaries" do
    test "redact_data_urls strips image bytes" do
      dirty = ~s(HTTP 400: {"error":{"message":"bad part near data:image/png;base64,AAAA=="})

      clean = CodeGen.redact_data_urls(dirty)
      assert clean =~ "data:image/*;base64,[redacted]"
      refute clean =~ "AAAA"
    end

    test "timeout message is plain language" do
      msg = CodeGen.timeout_message(600)
      assert msg =~ "600 s"
      assert msg =~ "try again, or ask for a simpler part"
      refute msg =~ "LLM request failed"
    end

    test "error_summary leads with the exception line" do
      tb = """
      Traceback (most recent call last):
        File "_harness.py", line 15, in <module>
        File "generated_code.py", line 22, in <module>
      RuntimeError: BuildPart doesn't have a Helix object or operation
      """

      headline = CodeGen.error_summary(tb)
      assert String.starts_with?(headline, "RuntimeError: BuildPart doesn't have a Helix")
      refute headline =~ "Traceback"
    end

    test "error_summary passthrough and empties" do
      assert CodeGen.error_summary("generated code never defines `part`") ==
               "generated code never defines `part`"

      assert CodeGen.error_summary("") == "unknown error"
      assert CodeGen.error_summary(nil) == "unknown error"
    end
  end
end
