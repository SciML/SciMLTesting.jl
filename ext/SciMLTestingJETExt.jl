module SciMLTestingJETExt

import SciMLTesting
import JET

function __init__()
    SciMLTesting._register_qa_tool!(:JET, JET)
    return nothing
end

end
