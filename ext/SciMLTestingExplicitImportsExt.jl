module SciMLTestingExplicitImportsExt

import SciMLTesting
import ExplicitImports

function __init__()
    SciMLTesting._register_qa_tool!(:ExplicitImports, ExplicitImports)
    return nothing
end

end