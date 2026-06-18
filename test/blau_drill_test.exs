defmodule BlauDrillTest do
  use ExUnit.Case, async: true

  test "the business-logic context module is defined" do
    assert Code.ensure_loaded?(BlauDrill)
  end
end
