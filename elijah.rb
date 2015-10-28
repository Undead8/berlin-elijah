require 'berlin-ai'
require 'priority_queue'

class Graph
  def initialize()
    @vertices = Hash.new
  end
  
  # Method to create a graph in a format that can be read by the shortest_path method.
  # The parameter edges must be a hash where the key is the edge, and the value is the distance from the parameter name to this edge.
  def add_vertex(name, edges)
    @vertices[name] = edges
  end
  
  # Method that find the shortest path between 2 nodes using the Dijkstra algorithm. 
  def shortest_path(start, finish)
    maxint = Float::INFINITY
    distances = Hash.new
    previous = Hash.new
    nodes = PriorityQueue.new
    
    @vertices.each do | vertex, value |
      if vertex == start
        distances[vertex] = 0
        nodes[vertex] = 0
      else
        distances[vertex] = maxint
        nodes[vertex] = maxint
      end
      previous[vertex] = nil
    end
    
    while nodes
      smallest = nodes.delete_min_return_key
      
      if smallest == finish
        path = Array.new
        while previous[smallest]
          path.push(smallest)
          smallest = previous[smallest]
        end
        return path.reverse
      end
      
      if smallest.nil? || distances[smallest] == maxint
        break            
      end
      
      @vertices[smallest].each do | neighbor, value | 
        alt = distances[smallest] + @vertices[smallest][neighbor]
        if alt < distances[neighbor]
          distances[neighbor] = alt
          previous[neighbor] = smallest
          nodes[neighbor] = alt
        end
      end
    end
  end
end

class Berlin::AI::Player

  # Method to calculate total soldiers in a list of nodes
  def self.soldiers_in_nodes(list_of_nodes)
    list_of_nodes.inject(0) { |sum, node| sum + node.number_of_soldiers }
  end

  # This method is used so that cities will generally keep as much soldiers as the total adjacent enemy soldiers.
  def self.soldiers_modifier(node, game) 
    free_cities = game.map.free_nodes.select { |free_node| free_node.soldiers_per_turn > 0 }

    if node.soldiers_per_turn <= 0 || game.turns_left < 5 || (node.adjacent_nodes & free_cities).any?
      return 0
    elsif node.adjacent_nodes.any? { |adj| adj.enemy? && adj.soldiers_per_turn > 0 && adj.number_of_soldiers < soldiers_in_nodes(adj.adjacent_nodes & game.map.owned_nodes) }
      return soldiers_in_nodes(node.adjacent_nodes & game.map.enemy_nodes) / 2
    else
      return soldiers_in_nodes(node.adjacent_nodes & game.map.enemy_nodes)
    end
  end

  # Method that returns a list of all the shortest paths from a node to a list of nodes, and sort it by length of paths.
  def self.shortest_paths_list(node, list_of_nodes, game)
    
    # Creates a graph of the game map.
    map_graph = Graph.new
    game.map.nodes.each do |node|

      # edges is a hash of the adjacent nodes (keys) and the distance between the adjacent node and the node (values).
      # Enemy soldiers on a node inscrease the distance from a node to this enemy node.
      edges = Hash.new
      node.adjacent_nodes.each do |adj|
        if adj.enemy?
          edges[adj] = 3 + adj.number_of_soldiers
        else 
          edges[adj] = 3
        end
      end
      
      map_graph.add_vertex(node, edges)
    end

    # Returns the sorted list of shortest paths from a node to a list of nodes.
    paths_list = list_of_nodes.map { |dest| map_graph.shortest_path(node, dest) }
    paths_list.shuffle.sort_by! { |path| path.length }
  end

  def self.on_turn(game)
   
    # attack_moves will store the moves from a node to another node when an attack is launched under Strategy 2.
    attack_moves = Hash.new
   
    # Useful lists of nodes.
    free_cities = game.map.free_nodes.select { |free_node| free_node.soldiers_per_turn > 0 }
    foreign_cities = game.map.foreign_nodes.select { |foreign_node| foreign_node.soldiers_per_turn > 0 }
    owned_cities = game.map.owned_nodes.select { |owned_node| owned_node.soldiers_per_turn > 0 }
    sorted_cities_first = game.map.controlled_nodes.sort { |x, y| y.soldiers_per_turn <=> x.soldiers_per_turn }
    sorted_nodes_first = game.map.controlled_nodes.sort { |x, y| x.soldiers_per_turn <=> y.soldiers_per_turn }

    # AI starts here.
    # As a priority, every node will reinforce any adjacent city that is outnumbered.    
    sorted_nodes_first.each do |node|

      # Only nodes and cities that have no adjacent free cities will reinforce.
      if node.soldiers_per_turn <= 0 || (node.adjacent_nodes & free_cities).empty?
        adjacent_cities = node.adjacent_nodes & owned_cities
        adjacent_cities.each do |destination|
          soldiers_to_move = [(soldiers_in_nodes(destination.adjacent_nodes & game.map.enemy_nodes) - destination.number_of_soldiers - destination.incoming_soldiers), (node.available_soldiers - soldiers_modifier(node, game))].min
          game.add_move(node, destination, soldiers_to_move) if soldiers_to_move > 0
        end
      end
    end

    # Then, the node will use one of the 3 strategies below.
    sorted_cities_first.each do |node|    

      # Strategy 1 - if there are free cities and if turn < 9 --> The soldiers will spread out towards at most 3 free cities.
      if free_cities.any? && game.current_turn < 9
        target_paths_list = shortest_paths_list(node, free_cities, game).take(3)
        target_paths_list.select! { |path| path.first.foreign? } if target_paths_list.any? { |path| path.first.foreign? }
        soldiers_left = node.available_soldiers - soldiers_modifier(node, game)
        target_paths_list.each do |path|
          destination = path.first
          soldiers_to_move = [((soldiers_left / target_paths_list.length.to_f).ceil), (node.available_soldiers - soldiers_modifier(node, game))].min
          game.add_move(node, destination, soldiers_to_move) if soldiers_to_move > 0
        end

      # Strategy 2 - if there is no free city or if turn >= 9, but there is foreign cities.
      elsif foreign_cities.any?
        
        # If we outnumber the enemy in at least a path towards a foreign city, the node will launch an attack towards the closest one.
        target_path = shortest_paths_list(node, foreign_cities, game).select { |path| (soldiers_in_nodes(path & game.map.enemy_nodes) < (node.available_soldiers - soldiers_modifier(node, game) + soldiers_in_nodes(path & game.map.owned_nodes))) || (path.last.number_of_soldiers < soldiers_in_nodes(path.last.adjacent_nodes & game.map.owned_nodes)) }.first
        if target_path && attack_moves[target_path.first.id] != node.id
          destination = target_path.first
          soldiers_to_move = node.available_soldiers - soldiers_modifier(node, game)
          game.add_move(node, destination, soldiers_to_move) if soldiers_to_move > 0
          attack_moves[node.id] = destination.id if soldiers_to_move > 0
        
        # If we are outnumbered in all shortest paths towards foreign cities, the node that is not a city will reinforce the closest owned city. Cities will do nothing (no else).
        elsif node.soldiers_per_turn <= 0 && node.incoming_soldiers <= 0
          destination = shortest_paths_list(node, owned_cities, game).first.first
          soldiers_to_move = node.available_soldiers
          game.add_move(node, destination, soldiers_to_move) if soldiers_to_move > 0
        end
      
      # Strategy 3 - when there is no more foreign cities --> Every owned nodes and cities will attack the closest foreign node.
      else
        destination = shortest_paths_list(node, game.map.foreign_nodes, game).first.first
        soldiers_to_move = node.available_soldiers - soldiers_modifier(node, game)
        game.add_move(node, destination, soldiers_to_move) if soldiers_to_move > 0
      end
    end
  end
end
