module SciMLTestingAquaExt

import SciMLTesting
import Aqua

function __init__()
    SciMLTesting._register_qa_tool!(:Aqua, Aqua)
    return nothing
end

end